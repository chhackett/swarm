{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- SPDX-License-Identifier: BSD-3-Clause
module Swarm.TUI.Model.StateUpdate (
  initAppState,
  initPersistentState,
  constructAppState,
  initAppStateForScenario,
  classicGame0,
  startGame,
  startGameWithSeed,
  restartGame,
  attainAchievement,
  attainAchievement',
  scenarioToAppState,
) where

import Brick.AttrMap (applyAttrMappings)
import Brick.Focus
import Brick.Widgets.List qualified as BL
import Control.Applicative ((<|>))
import Control.Carrier.Accum.FixedStrict (runAccum)
import Control.Carrier.Lift (runM)
import Control.Carrier.Throw.Either (runThrow)
import Control.Effect.Accum
import Control.Effect.Lift
import Control.Effect.Throw
import Control.Lens hiding (from, (<.>))
import Control.Monad (guard, void)
import Control.Monad.Except (ExceptT (..))
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.State (MonadState, execStateT)
import Data.Foldable qualified as F
import Data.List qualified as List
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as M
import Data.Maybe (fromMaybe, isJust)
import Data.Sequence (Seq)
import Data.Text (Text)
import Data.Time (ZonedTime, getZonedTime)
import Swarm.Game.Achievement.Attainment
import Swarm.Game.Achievement.Definitions
import Swarm.Game.Achievement.Persistence
import Swarm.Game.Failure (SystemFailure)
import Swarm.Game.Scenario (loadScenario, scenarioAttrs, scenarioWorlds)
import Swarm.Game.Scenario.Scoring.Best
import Swarm.Game.Scenario.Scoring.ConcreteMetrics
import Swarm.Game.Scenario.Scoring.GenericMetrics
import Swarm.Game.Scenario.Status
import Swarm.Game.Scenario.Topography.Structure.Recognition (automatons)
import Swarm.Game.Scenario.Topography.Structure.Recognition.Type (definitions)
import Swarm.Game.ScenarioInfo (
  loadScenarioInfo,
  normalizeScenarioPath,
  scenarioItemByPath,
  scenarioSolution,
  _SISingle,
 )
import Swarm.Game.State
import Swarm.Language.Pretty (prettyText)
import Swarm.Log (LogSource (SystemLog), Severity (..))
import Swarm.TUI.Editor.Model qualified as EM
import Swarm.TUI.Editor.Util qualified as EU
import Swarm.TUI.Inventory.Sorting
import Swarm.TUI.Launch.Model (toSerializableParams)
import Swarm.TUI.Model
import Swarm.TUI.Model.Goal (emptyGoalDisplay)
import Swarm.TUI.Model.Name
import Swarm.TUI.Model.Repl
import Swarm.TUI.Model.Structure
import Swarm.TUI.Model.UI
import Swarm.TUI.View.Attribute.Attr (swarmAttrMap)
import Swarm.TUI.View.Attribute.CustomStyling (toAttrPair)
import Swarm.TUI.View.Structure qualified as SR
import Swarm.Util (listEnums)
import Swarm.Util.Effect (asExceptT, withThrow)
import System.Clock

-- | Initialize the 'AppState' from scratch.
initAppState ::
  (Has (Throw SystemFailure) sig m, Has (Lift IO) sig m) =>
  AppOpts ->
  m AppState
initAppState opts = do
  (rs, ui) <- initPersistentState opts
  constructAppState rs ui opts

-- | Add some system failures to the list of messages in the
--   'RuntimeState'.
addWarnings :: RuntimeState -> [SystemFailure] -> RuntimeState
addWarnings = List.foldl' logWarning
 where
  logWarning rs' w = rs' & eventLog %~ logEvent SystemLog Error "UI Loading" (prettyText w)

-- | Based on the command line options, should we skip displaying the
--   menu?
skipMenu :: AppOpts -> Bool
skipMenu AppOpts {..} = isJust userScenario || isRunningInitialProgram || isJust userSeed
 where
  isRunningInitialProgram = isJust scriptToRun || autoPlay

-- | Initialize the more persistent parts of the app state, /i.e./ the
--   'RuntimeState' and 'UIState'.  This is split out into a separate
--   function so that in the integration test suite we can call this
--   once and reuse the resulting states for all tests.
initPersistentState ::
  (Has (Throw SystemFailure) sig m, Has (Lift IO) sig m) =>
  AppOpts ->
  m (RuntimeState, UIState)
initPersistentState opts@(AppOpts {..}) = do
  (warnings :: Seq SystemFailure, (initRS, initUI)) <- runAccum mempty $ do
    rs <- initRuntimeState
    ui <- initUIState speed (not (skipMenu opts)) cheatMode
    return (rs, ui)
  let initRS' = addWarnings initRS (F.toList warnings)
  return (initRS', initUI)

-- | Construct an 'AppState' from an already-loaded 'RuntimeState' and
--   'UIState', given the 'AppOpts' the app was started with.
constructAppState ::
  (Has (Throw SystemFailure) sig m, Has (Lift IO) sig m) =>
  RuntimeState ->
  UIState ->
  AppOpts ->
  m AppState
constructAppState rs ui opts@(AppOpts {..}) = do
  let gs = initGameState (mkGameStateConfig rs)
  case skipMenu opts of
    False -> return $ AppState gs (ui & lgTicksPerSecond .~ defaultInitLgTicksPerSecond) rs
    True -> do
      (scenario, path) <- loadScenario (fromMaybe "classic" userScenario) (gs ^. landscape . entityMap) (rs ^. worlds)
      maybeRunScript <- traverse parseCodeFile scriptToRun

      let maybeAutoplay = do
            guard autoPlay
            soln <- scenario ^. scenarioSolution
            return $ CodeToRun ScenarioSuggested soln
          codeToRun = maybeAutoplay <|> maybeRunScript

      eitherSi <- sendIO . runM . runThrow $ loadScenarioInfo path
      let (si, newRs) = case eitherSi of
            Right x -> (x, rs)
            Left e -> (ScenarioInfo path NotStarted, addWarnings rs [e])
      sendIO $
        execStateT
          (startGameWithSeed (scenario, si) $ LaunchParams (pure userSeed) (pure codeToRun))
          (AppState gs ui newRs)

-- | Load a 'Scenario' and start playing the game.
startGame :: (MonadIO m, MonadState AppState m) => ScenarioInfoPair -> Maybe CodeToRun -> m ()
startGame siPair = startGameWithSeed siPair . LaunchParams (pure Nothing) . pure

-- | Re-initialize the game from the stored reference to the current scenario.
--
-- Note that "restarting" is intended only for "scenarios";
-- with some scenarios, it may be possible to get stuck so that it is
-- either impossible or very annoying to win, so being offered an
-- option to restart is more user-friendly.
--
-- Since scenarios are stored as a Maybe in the UI state, we handle the Nothing
-- case upstream so that the Scenario passed to this function definitely exists.
restartGame :: (MonadIO m, MonadState AppState m) => Seed -> ScenarioInfoPair -> m ()
restartGame currentSeed siPair = startGameWithSeed siPair $ LaunchParams (pure (Just currentSeed)) (pure Nothing)

-- | Load a 'Scenario' and start playing the game, with the
--   possibility for the user to override the seed.
startGameWithSeed ::
  (MonadIO m, MonadState AppState m) =>
  ScenarioInfoPair ->
  ValidatedLaunchParams ->
  m ()
startGameWithSeed siPair@(_scene, si) lp = do
  t <- liftIO getZonedTime
  ss <- use $ runtimeState . scenarios
  p <- liftIO $ normalizeScenarioPath ss (si ^. scenarioPath)
  runtimeState
    . scenarios
    . scenarioItemByPath p
    . _SISingle
    . _2
    . scenarioStatus
    .= Played
      (toSerializableParams lp)
      (Metric Attempted $ ProgressStats t emptyAttemptMetric)
      (prevBest t)
  scenarioToAppState siPair lp
  -- Beware: currentScenarioPath must be set so that progress/achievements can be saved.
  -- It has just been cleared in scenarioToAppState.
  gameState . currentScenarioPath .= Just p
 where
  prevBest t = case si ^. scenarioStatus of
    NotStarted -> emptyBest t
    Played _ _ b -> b

-- | Modify the 'AppState' appropriately when starting a new scenario.
scenarioToAppState ::
  (MonadIO m, MonadState AppState m) =>
  ScenarioInfoPair ->
  ValidatedLaunchParams ->
  m ()
scenarioToAppState siPair@(scene, _) lp = do
  rs <- use runtimeState
  gs <- liftIO $ scenarioToGameState scene lp $ mkGameStateConfig rs
  gameState .= gs
  void $ withLensIO uiState $ scenarioToUIState isAutoplaying siPair gs
 where
  isAutoplaying = case runIdentity (initialCode lp) of
    Just (CodeToRun ScenarioSuggested _) -> True
    _ -> False

  withLensIO :: (MonadIO m, MonadState AppState m) => Lens' AppState x -> (x -> IO x) -> m x
  withLensIO l a = do
    x <- use l
    x' <- liftIO $ a x
    l .= x'
    return x'

attainAchievement :: (MonadIO m, MonadState AppState m) => CategorizedAchievement -> m ()
attainAchievement a = do
  currentTime <- liftIO getZonedTime
  attainAchievement' currentTime Nothing a

attainAchievement' ::
  (MonadIO m, MonadState AppState m) =>
  ZonedTime ->
  Maybe FilePath ->
  CategorizedAchievement ->
  m ()
attainAchievement' t p a = do
  (uiState . uiAchievements)
    %= M.insertWith
      (<>)
      a
      (Attainment a p t)
  newAchievements <- use $ uiState . uiAchievements
  liftIO $ saveAchievementsInfo $ M.elems newAchievements

-- | Modify the UI state appropriately when starting a new scenario.
scenarioToUIState ::
  Bool ->
  ScenarioInfoPair ->
  GameState ->
  UIState ->
  IO UIState
scenarioToUIState isAutoplaying siPair@(scenario, _) gs u = do
  curTime <- getTime Monotonic
  return $
    u
      & uiPlaying .~ True
      & uiGoal .~ emptyGoalDisplay
      & uiCheatMode ||~ isAutoplaying
      & uiHideGoals .~ (isAutoplaying && not (u ^. uiCheatMode))
      & uiFocusRing .~ initFocusRing
      & uiInventory .~ Nothing
      & uiInventorySort .~ defaultSortOptions
      & uiShowFPS .~ False
      & uiShowZero .~ True
      & uiREPL .~ initREPLState (u ^. uiREPL . replHistory)
      & uiREPL . replHistory %~ restartREPLHistory
      & uiAttrMap .~ applyAttrMappings (map toAttrPair $ fst siPair ^. scenarioAttrs) swarmAttrMap
      & scenarioRef ?~ siPair
      & lastFrameTime .~ curTime
      & uiWorldEditor . EM.entityPaintList %~ BL.listReplace entityList Nothing
      & uiWorldEditor . EM.editingBounds . EM.boundsRect %~ setNewBounds
      & uiStructure
        .~ StructureDisplay
          (SR.makeListWidget $ gs ^. discovery . structureRecognition . automatons . definitions)
          (focusSetCurrent (StructureWidgets StructuresList) $ focusRing $ map StructureWidgets listEnums)
 where
  entityList = EU.getEntitiesForList $ gs ^. landscape . entityMap

  (isEmptyArea, newBounds) = EU.getEditingBounds $ NE.head $ scenario ^. scenarioWorlds
  setNewBounds maybeOldBounds =
    if isEmptyArea
      then maybeOldBounds
      else Just newBounds

-- | Create an initial app state for a specific scenario.  Note that
--   this function is used only for unit tests, integration tests, and
--   benchmarks.
--
--   In normal play, an 'AppState' already exists and we simply need
--   to update it using 'scenarioToAppState'.
initAppStateForScenario :: String -> Maybe Seed -> Maybe FilePath -> ExceptT Text IO AppState
initAppStateForScenario sceneName userSeed toRun =
  asExceptT . withThrow (prettyText @SystemFailure) . initAppState $
    defaultAppOpts
      { userScenario = Just sceneName
      , userSeed = userSeed
      , scriptToRun = toRun
      }

-- | For convenience, the 'AppState' corresponding to the classic game
--   with seed 0.  This is used only for benchmarks and unit tests.
classicGame0 :: ExceptT Text IO AppState
classicGame0 = initAppStateForScenario "classic" (Just 0) Nothing
