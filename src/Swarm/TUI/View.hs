{-# LANGUAGE OverloadedStrings #-}

-- |
-- SPDX-License-Identifier: BSD-3-Clause
--
-- Code for drawing the TUI.
module Swarm.TUI.View (
  drawUI,
  drawTPS,

  -- * Dialog box
  drawDialog,
  chooseCursor,

  -- * Key hint menu
  drawKeyMenu,
  drawModalMenu,
  drawKeyCmd,

  -- * World
  drawWorldPane,

  -- * Robot panel
  drawRobotPanel,
  drawItem,
  renderDutyCycle,

  -- * Info panel
  drawInfoPanel,
  explainFocusedItem,

  -- * REPL
  drawREPL,
) where

import Brick hiding (Direction, Location)
import Brick.Focus
import Brick.Forms
import Brick.Widgets.Border (
  hBorder,
  hBorderWithLabel,
  joinableBorder,
  vBorder,
 )
import Brick.Widgets.Center (center, centerLayer, hCenter)
import Brick.Widgets.Dialog
import Brick.Widgets.Edit (getEditContents, renderEditor)
import Brick.Widgets.List qualified as BL
import Brick.Widgets.Table qualified as BT
import Control.Lens as Lens hiding (Const, from)
import Control.Monad (guard)
import Data.Array (range)
import Data.Bits (shiftL, shiftR, (.&.))
import Data.Foldable (toList)
import Data.Foldable qualified as F
import Data.Functor (($>))
import Data.IntMap qualified as IM
import Data.List (intersperse)
import Data.List qualified as L
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.List.Split (chunksOf)
import Data.Map qualified as M
import Data.Maybe (catMaybes, fromMaybe, isJust, listToMaybe, mapMaybe, maybeToList)
import Data.Semigroup (sconcat)
import Data.Sequence qualified as Seq
import Data.Set qualified as Set (toList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, defaultTimeLocale, formatTime)
import Linear
import Network.Wai.Handler.Warp (Port)
import Numeric (showFFloat)
import Swarm.Constant
import Swarm.Game.CESK (CESK (..), TickNumber (..), addTicks)
import Swarm.Game.Display
import Swarm.Game.Entity as E
import Swarm.Game.Location
import Swarm.Game.Recipe
import Swarm.Game.Robot
import Swarm.Game.Scenario (
  scenarioAuthor,
  scenarioCreative,
  scenarioDescription,
  scenarioKnown,
  scenarioName,
  scenarioObjectives,
  scenarioSeed,
 )
import Swarm.Game.Scenario.Scoring.Best
import Swarm.Game.Scenario.Scoring.CodeSize
import Swarm.Game.Scenario.Scoring.ConcreteMetrics
import Swarm.Game.Scenario.Scoring.GenericMetrics
import Swarm.Game.Scenario.Status
import Swarm.Game.Scenario.Topography.Structure.Recognition (automatons)
import Swarm.Game.Scenario.Topography.Structure.Recognition.Type
import Swarm.Game.ScenarioInfo (
  ScenarioItem (..),
  scenarioItemName,
 )
import Swarm.Game.State
import Swarm.Game.Universe
import Swarm.Game.World qualified as W
import Swarm.Language.Capability (Capability (..), constCaps)
import Swarm.Language.Pretty (prettyText, prettyTextLine)
import Swarm.Language.Syntax
import Swarm.Language.Typecheck (inferConst)
import Swarm.Log
import Swarm.TUI.Border
import Swarm.TUI.Controller (ticksPerFrameCap)
import Swarm.TUI.Editor.Model
import Swarm.TUI.Editor.View qualified as EV
import Swarm.TUI.Inventory.Sorting (renderSortMethod)
import Swarm.TUI.Launch.Model
import Swarm.TUI.Launch.View
import Swarm.TUI.Model
import Swarm.TUI.Model.Goal (goalsContent, hasAnythingToShow)
import Swarm.TUI.Model.Repl (getSessionREPLHistoryItems, lastEntry)
import Swarm.TUI.Model.UI
import Swarm.TUI.Panel
import Swarm.TUI.View.Achievement
import Swarm.TUI.View.Attribute.Attr
import Swarm.TUI.View.CellDisplay
import Swarm.TUI.View.Objective qualified as GR
import Swarm.TUI.View.Structure qualified as SR
import Swarm.TUI.View.Util as VU
import Swarm.Util
import Swarm.Util.UnitInterval
import Swarm.Util.WindowedCounter qualified as WC
import Swarm.Version (NewReleaseFailure (..))
import System.Clock (TimeSpec (..))
import Text.Printf
import Text.Wrap
import Witch (into)

-- | The main entry point for drawing the entire UI.  Figures out
--   which menu screen we should show (if any), or just the game itself.
drawUI :: AppState -> [Widget Name]
drawUI s
  | s ^. uiState . uiPlaying = drawGameUI s
  | otherwise = case s ^. uiState . uiMenu of
      -- We should never reach the NoMenu case if uiPlaying is false; we would have
      -- quit the app instead.  But just in case, we display the main menu anyway.
      NoMenu -> [drawMainMenuUI s (mainMenu NewGame)]
      MainMenu l -> [drawMainMenuUI s l]
      NewGameMenu stk -> drawNewGameMenuUI stk $ s ^. uiState . uiLaunchConfig
      AchievementsMenu l -> [drawAchievementsMenuUI s l]
      MessagesMenu -> [drawMainMessages s]
      AboutMenu -> [drawAboutMenuUI (s ^. runtimeState . appData . at "about")]

drawMainMessages :: AppState -> Widget Name
drawMainMessages s = renderDialog dial . padBottom Max . scrollList $ drawLogs ls
 where
  ls = reverse $ s ^. runtimeState . eventLog . notificationsContent
  dial = dialog (Just $ str "Messages") Nothing maxModalWindowWidth
  scrollList = withVScrollBars OnRight . vBox
  drawLogs = map (drawLogEntry True)

drawMainMenuUI :: AppState -> BL.List Name MainMenuEntry -> Widget Name
drawMainMenuUI s l =
  vBox . catMaybes $
    [ drawLogo <$> logo
    , hCenter . padTopBottom 2 <$> newVersionWidget version
    , Just . centerLayer . vLimit 6 . hLimit 20 $
        BL.renderList (const (hCenter . drawMainMenuEntry s)) True l
    ]
 where
  logo = s ^. runtimeState . appData . at "logo"
  version = s ^. runtimeState . upstreamRelease

newVersionWidget :: Either NewReleaseFailure String -> Maybe (Widget n)
newVersionWidget = \case
  Right ver -> Just . txt $ "New version " <> T.pack ver <> " is available!"
  Left (OnDevelopmentBranch _b) -> Just . txt $ "Good luck developing!"
  Left (FailedReleaseQuery _f) -> Nothing
  Left (NoMainUpstreamRelease _fails) -> Nothing
  Left (OldUpstreamRelease _up _my) -> Nothing

drawLogo :: Text -> Widget Name
drawLogo = centerLayer . vBox . map (hBox . T.foldr (\c ws -> drawThing c : ws) []) . T.lines
 where
  drawThing :: Char -> Widget Name
  drawThing c = withAttr (attrFor c) $ str [c]

  attrFor :: Char -> AttrName
  attrFor c
    | c `elem` ("<>v^" :: String) = robotAttr
  attrFor 'T' = plantAttr
  attrFor '@' = rockAttr
  attrFor '~' = waterAttr
  attrFor '▒' = dirtAttr
  attrFor _ = defAttr

-- | When launching a game, a modal prompt may appear on another layer
-- to input seed and/or a script to run.
drawNewGameMenuUI ::
  NonEmpty (BL.List Name ScenarioItem) ->
  LaunchOptions ->
  [Widget Name]
drawNewGameMenuUI (l :| ls) launchOptions = case displayedFor of
  Nothing -> pure mainWidget
  Just _ -> drawLaunchConfigPanel launchOptions <> pure mainWidget
 where
  displayedFor = launchOptions ^. controls . isDisplayedFor
  mainWidget =
    vBox
      [ padLeftRight 20
          . centerLayer
          $ hBox
            [ vBox
                [ withAttr boldAttr . txt $ breadcrumbs ls
                , txt " "
                , vLimit 20
                    . hLimit 35
                    . BL.renderList (const $ padRight Max . drawScenarioItem) True
                    $ l
                ]
            , padLeft (Pad 5) (maybe (txt "") (drawDescription . snd) (BL.listSelectedElement l))
            ]
      , launchOptionsMessage
      ]

  launchOptionsMessage = case (displayedFor, snd <$> BL.listSelectedElement l) of
    (Nothing, Just (SISingle _)) -> hCenter $ txt "Press 'o' for launch options, or 'Enter' to launch with defaults"
    _ -> txt " "

  drawScenarioItem (SISingle (s, si)) = padRight (Pad 1) (drawStatusInfo s si) <+> txt (s ^. scenarioName)
  drawScenarioItem (SICollection nm _) = padRight (Pad 1) (withAttr boldAttr $ txt " > ") <+> txt nm
  drawStatusInfo s si = case si ^. scenarioStatus of
    NotStarted -> txt " ○ "
    Played _initialScript (Metric Attempted _) _ -> case s ^. scenarioObjectives of
      [] -> withAttr cyanAttr $ txt " ◉ "
      _ -> withAttr yellowAttr $ txt " ◎ "
    Played _initialScript (Metric Completed _) _ -> withAttr greenAttr $ txt " ● "

  describeStatus :: ScenarioStatus -> Widget n
  describeStatus = \case
    NotStarted -> withAttr cyanAttr $ txt "not started"
    Played _initialScript pm _best -> describeProgress pm

  breadcrumbs :: [BL.List Name ScenarioItem] -> Text
  breadcrumbs =
    T.intercalate " > "
      . ("Scenarios" :)
      . reverse
      . mapMaybe (fmap (scenarioItemName . snd) . BL.listSelectedElement)

  drawDescription :: ScenarioItem -> Widget Name
  drawDescription (SICollection _ _) = txtWrap " "
  drawDescription (SISingle (s, si)) =
    vBox
      [ drawMarkdown (nonBlank (s ^. scenarioDescription))
      , hCenter . padTop (Pad 1) . vLimit 6 $ hLimitPercent 60 worldPeek
      , padTop (Pad 1) table
      ]
   where
    defaultVC = Cosmic DefaultRootSubworld origin

    -- The first robot is guaranteed to be the base.
    baseRobotLoc :: Maybe (Cosmic Location)
    baseRobotLoc = do
      theBaseRobot <- listToMaybe theRobots
      view trobotLocation theBaseRobot

    vc = fromMaybe defaultVC baseRobotLoc

    worldTuples = buildWorldTuples s
    theWorlds = genMultiWorld worldTuples $ fromMaybe 0 $ s ^. scenarioSeed
    theRobots = genRobotTemplates s worldTuples

    ri =
      RenderingInput theWorlds $
        getEntityIsKnown $
          EntityKnowledgeDependencies
            { isCreativeMode = s ^. scenarioCreative
            , globallyKnownEntities = s ^. scenarioKnown
            , theFocusedRobot = Nothing
            }
    renderCoord = renderDisplay . displayLocRaw (WorldOverdraw False mempty) ri []
    worldPeek = worldWidget renderCoord vc

    firstRow =
      ( withAttr dimAttr $ txt "Author:"
      , withAttr dimAttr . txt <$> s ^. scenarioAuthor
      )
    secondRow =
      ( txt "last:"
      , Just $ describeStatus $ si ^. scenarioStatus
      )

    padTopLeft = padTop (Pad 1) . padLeft (Pad 1)

    tableRows =
      map (map padTopLeft . pairToList) $
        mapMaybe sequenceA $
          firstRow : secondRow : makeBestScoreRows (si ^. scenarioStatus)
    table =
      BT.renderTable
        . BT.surroundingBorder False
        . BT.rowBorders False
        . BT.columnBorders False
        . BT.alignRight 0
        . BT.alignLeft 1
        . BT.table
        $ tableRows

  nonBlank "" = " "
  nonBlank t = t

pairToList :: (a, a) -> [a]
pairToList (x, y) = [x, y]

describeProgress :: ProgressMetric -> Widget n
describeProgress (Metric p (ProgressStats _startedAt (AttemptMetrics (DurationMetrics e t) maybeCodeMetrics))) = case p of
  Attempted ->
    withAttr yellowAttr . vBox $
      [ txt "in progress"
      , txt $ parens $ T.unwords ["played for", formatTimeDiff e]
      ]
  Completed ->
    withAttr greenAttr . vBox $
      [ txt $ T.unwords ["completed in", formatTimeDiff e]
      , txt . (" " <>) . parens $ T.unwords [T.pack $ drawTime t True, "ticks"]
      ]
        <> maybeToList (sizeDisplay <$> maybeCodeMetrics)
   where
    sizeDisplay (ScenarioCodeMetrics myCharCount myAstSize) =
      withAttr greenAttr $
        vBox $
          map
            txt
            [ T.unwords
                [ "Code:"
                , T.pack $ show myCharCount
                , "chars"
                ]
            , (" " <>) $
                parens $
                  T.unwords
                    [ T.pack $ show myAstSize
                    , "AST nodes"
                    ]
            ]
 where
  formatTimeDiff :: NominalDiffTime -> Text
  formatTimeDiff = T.pack . formatTime defaultTimeLocale "%hh %Mm %Ss"

-- | If there are multiple different games that each are \"best\"
-- by different criteria, display them all separately, labeled
-- by which criteria they were best in.
--
-- On the other hand, if all of the different \"best\" criteria are for the
-- same game, consolidate them all into one entry and don't bother
-- labelling the criteria.
makeBestScoreRows ::
  ScenarioStatus ->
  [(Widget n1, Maybe (Widget n2))]
makeBestScoreRows scenarioStat =
  maybe [] makeBestRows getBests
 where
  getBests = case scenarioStat of
    NotStarted -> Nothing
    Played _initialScript _ best -> Just best

  makeBestRows b = map (makeBestRow hasMultiple) groups
   where
    groups = getBestGroups b
    hasMultiple = length groups > 1

  makeBestRow hasDistinctByCriteria (b, criteria) =
    ( hLimit (maxLeftColumnWidth + 2) $
        vBox $
          [ padLeft Max $ txt "best:"
          ]
            <> elaboratedCriteria
    , Just $ describeProgress b
    )
   where
    maxLeftColumnWidth = maximum (map (T.length . describeCriteria) listEnums)
    mkCriteriaRow =
      withAttr dimAttr
        . padLeft Max
        . txt
        . mconcat
        . pairToList
        . fmap (\x -> T.singleton $ if x == 0 then ',' else ' ')
    elaboratedCriteria =
      if hasDistinctByCriteria
        then
          map mkCriteriaRow
            . flip zip [(0 :: Int) ..]
            . NE.toList
            . NE.reverse
            . NE.map describeCriteria
            $ criteria
        else []

drawMainMenuEntry :: AppState -> MainMenuEntry -> Widget Name
drawMainMenuEntry s = \case
  NewGame -> txt "New game"
  Tutorial -> txt "Tutorial"
  Achievements -> txt "Achievements"
  About -> txt "About"
  Messages -> highlightMessages $ txt "Messages"
  Quit -> txt "Quit"
 where
  highlightMessages =
    if s ^. runtimeState . eventLog . notificationsCount > 0
      then withAttr notifAttr
      else id

drawAboutMenuUI :: Maybe Text -> Widget Name
drawAboutMenuUI Nothing = centerLayer $ txt "About swarm!"
drawAboutMenuUI (Just t) = centerLayer . vBox . map (hCenter . txt . nonblank) $ T.lines t
 where
  -- Turn blank lines into a space so they will take up vertical space as widgets
  nonblank "" = " "
  nonblank s = s

-- | Draw the main game UI.  Generates a list of widgets, where each
--   represents a layer.  Right now we just generate two layers: the
--   main layer and a layer for a floating dialog that can be on top.
drawGameUI :: AppState -> [Widget Name]
drawGameUI s =
  [ joinBorders $ drawDialog s
  , joinBorders $
      hBox
        [ hLimitPercent 25 $
            vBox
              [ vLimitPercent 50
                  $ panel
                    highlightAttr
                    fr
                    (FocusablePanel RobotPanel)
                    ( plainBorder
                        & bottomLabels . centerLabel
                          .~ fmap
                            (txt . (" Search: " <>) . (<> " "))
                            (s ^. uiState . uiInventorySearch)
                    )
                  $ drawRobotPanel s
              , panel
                  highlightAttr
                  fr
                  (FocusablePanel InfoPanel)
                  plainBorder
                  $ drawInfoPanel s
              , hCenter
                  . clickable (FocusablePanel WorldEditorPanel)
                  . EV.drawWorldEditor fr
                  $ s ^. uiState
              ]
        , vBox rightPanel
        ]
  ]
 where
  addCursorPos = bottomLabels . leftLabel ?~ padLeftRight 1 widg
   where
    widg = case s ^. uiState . uiWorldCursor of
      Nothing -> str $ renderCoordsString $ s ^. gameState . viewCenter
      Just coord -> clickable WorldPositionIndicator $ drawWorldCursorInfo (s ^. uiState . uiWorldEditor . worldOverdraw) (s ^. gameState) coord
  -- Add clock display in top right of the world view if focused robot
  -- has a clock equipped
  addClock = topLabels . rightLabel ?~ padLeftRight 1 (drawClockDisplay (s ^. uiState . lgTicksPerSecond) $ s ^. gameState)
  fr = s ^. uiState . uiFocusRing
  showREPL = s ^. uiState . uiShowREPL
  rightPanel = if showREPL then worldPanel ++ replPanel else worldPanel ++ minimizedREPL
  minimizedREPL = case focusGetCurrent fr of
    (Just (FocusablePanel REPLPanel)) -> [separateBorders $ clickable (FocusablePanel REPLPanel) (forceAttr highlightAttr hBorder)]
    _ -> [separateBorders $ clickable (FocusablePanel REPLPanel) hBorder]
  worldPanel =
    [ panel
        highlightAttr
        fr
        (FocusablePanel WorldPanel)
        ( plainBorder
            & bottomLabels . rightLabel ?~ padLeftRight 1 (drawTPS s)
            & topLabels . leftLabel ?~ drawModalMenu s
            & addCursorPos
            & addClock
        )
        (drawWorldPane (s ^. uiState) (s ^. gameState))
    , drawKeyMenu s
    ]
  replPanel =
    [ clickable (FocusablePanel REPLPanel) $
        panel
          highlightAttr
          fr
          (FocusablePanel REPLPanel)
          ( plainBorder
              & topLabels . rightLabel .~ (drawType <$> (s ^. uiState . uiREPL . replType))
          )
          ( vLimit replHeight
              . padBottom Max
              . padLeft (Pad 1)
              $ drawREPL s
          )
    ]

renderCoordsString :: Cosmic Location -> String
renderCoordsString (Cosmic sw coords) =
  unwords $ VU.locationToString coords : suffix
 where
  suffix = case sw of
    DefaultRootSubworld -> []
    SubworldName swName -> ["in", T.unpack swName]

drawWorldCursorInfo :: WorldOverdraw -> GameState -> Cosmic W.Coords -> Widget Name
drawWorldCursorInfo worldEditor g cCoords =
  case getStatic g coords of
    Just s -> renderDisplay $ displayStatic s
    Nothing -> hBox $ tileMemberWidgets ++ [coordsWidget]
 where
  Cosmic _ coords = cCoords
  coordsWidget = str $ renderCoordsString $ fmap W.coordsToLoc cCoords

  tileMembers = terrain : mapMaybe merge [entity, robot]
  tileMemberWidgets =
    map (padRight $ Pad 1)
      . concat
      . reverse
      . zipWith f tileMembers
      $ ["at", "on", "with"]
   where
    f cell preposition = [renderDisplay cell, txt preposition]

  ri = RenderingInput (g ^. landscape . multiWorld) (getEntityIsKnown $ mkEntityKnowledge g)
  terrain = displayTerrainCell worldEditor ri cCoords
  entity = displayEntityCell worldEditor ri cCoords
  robot = displayRobotCell g cCoords

  merge = fmap sconcat . NE.nonEmpty . filter (not . (^. invisible))

-- | Format the clock display to be shown in the upper right of the
--   world panel.
drawClockDisplay :: Int -> GameState -> Widget n
drawClockDisplay lgTPS gs = hBox . intersperse (txt " ") $ catMaybes [clockWidget, pauseWidget]
 where
  clockWidget = maybeDrawTime (gs ^. temporal . ticks) (gs ^. temporal . paused || lgTPS < 3) gs
  pauseWidget = guard (gs ^. temporal . paused) $> txt "(PAUSED)"

-- | Check whether the currently focused robot (if any) has a clock
--   device equipped.
clockEquipped :: GameState -> Bool
clockEquipped gs = case focusedRobot gs of
  Nothing -> False
  Just r
    | countByName "clock" (r ^. equippedDevices) > 0 -> True
    | otherwise -> False

-- | Format a ticks count as a hexadecimal clock.
drawTime :: TickNumber -> Bool -> String
drawTime (TickNumber t) showTicks =
  mconcat $
    intersperse
      ":"
      [ printf "%x" (t `shiftR` 20)
      , printf "%02x" ((t `shiftR` 12) .&. ((1 `shiftL` 8) - 1))
      , printf "%02x" ((t `shiftR` 4) .&. ((1 `shiftL` 8) - 1))
      ]
      ++ if showTicks then [".", printf "%x" (t .&. ((1 `shiftL` 4) - 1))] else []

-- | Return a possible time display, if the currently focused robot
--   has a clock device equipped.  The first argument is the number
--   of ticks (e.g. 943 = 0x3af), and the second argument indicates
--   whether the time should be shown down to single-tick resolution
--   (e.g. 0:00:3a.f) or not (e.g. 0:00:3a).
maybeDrawTime :: TickNumber -> Bool -> GameState -> Maybe (Widget n)
maybeDrawTime t showTicks gs = guard (clockEquipped gs) $> str (drawTime t showTicks)

-- | Draw info about the current number of ticks per second.
drawTPS :: AppState -> Widget Name
drawTPS s = hBox (tpsInfo : rateInfo)
 where
  tpsInfo
    | l >= 0 = hBox [str (show n), txt " ", txt (number n "tick"), txt " / s"]
    | otherwise = hBox [txt "1 tick / ", str (show n), txt " s"]

  rateInfo
    | s ^. uiState . uiShowFPS =
        [ txt " ("
        , let tpf = s ^. uiState . uiTPF
           in (if tpf >= fromIntegral ticksPerFrameCap then withAttr redAttr else id)
                (str (printf "%0.1f" tpf))
        , txt " tpf, "
        , str (printf "%0.1f" (s ^. uiState . uiFPS))
        , txt " fps)"
        ]
    | otherwise = []

  l = s ^. uiState . lgTicksPerSecond
  n = 2 ^ abs l

-- | The height of the REPL box.  Perhaps in the future this should be
--   configurable.
replHeight :: Int
replHeight = 10

-- | Hide the cursor when a modal is set
chooseCursor :: AppState -> [CursorLocation n] -> Maybe (CursorLocation n)
chooseCursor s locs = case s ^. uiState . uiModal of
  Nothing -> showFirstCursor s locs
  Just _ -> Nothing

-- | Draw a dialog window, if one should be displayed right now.
drawDialog :: AppState -> Widget Name
drawDialog s = case s ^. uiState . uiModal of
  Just (Modal mt d) -> renderDialog d $ case mt of
    GoalModal -> drawModal s mt
    _ -> maybeScroll ModalViewport $ drawModal s mt
  Nothing -> emptyWidget

-- | Draw one of the various types of modal dialog.
drawModal :: AppState -> ModalType -> Widget Name
drawModal s = \case
  HelpModal -> helpWidget (s ^. gameState . seed) (s ^. runtimeState . webPort)
  RobotsModal -> robotsListWidget s
  RecipesModal -> availableListWidget (s ^. gameState) RecipeList
  CommandsModal -> commandsListWidget (s ^. gameState)
  MessagesModal -> availableListWidget (s ^. gameState) MessageList
  StructuresModal -> SR.renderStructuresDisplay (s ^. gameState) (s ^. uiState . uiStructure)
  ScenarioEndModal outcome ->
    padBottom (Pad 1) $
      vBox $
        map
          (hCenter . txt)
          content
   where
    content = case outcome of
      WinModal -> ["Congratulations!"]
      LoseModal ->
        [ "Condolences!"
        , "This scenario is no longer winnable."
        ]
  DescriptionModal e -> descriptionWidget s e
  QuitModal -> padBottom (Pad 1) $ hCenter $ txt (quitMsg (s ^. uiState . uiMenu))
  GoalModal -> GR.renderGoalsDisplay (s ^. uiState . uiGoal)
  KeepPlayingModal ->
    padLeftRight 1 $
      displayParagraphs $
        pure
          "Have fun!  Hit Ctrl-Q whenever you're ready to proceed to the next challenge or return to the menu."
  TerrainPaletteModal -> EV.drawTerrainSelector s
  EntityPaletteModal -> EV.drawEntityPaintSelector s

-- | Render the percentage of ticks that this robot was active.
-- This indicator can take some time to "warm up" and stabilize
-- due to the sliding window.
--
-- == Use of previous tick
-- The 'Swarm.Game.Step.gameTick' function runs all robots, then increments the current tick.
-- So at the time we are rendering a frame, the current tick will always be
-- strictly greater than any ticks stored in the 'WC.WindowedCounter' for any robot;
-- hence 'WC.getOccupancy' will never be @1@ if we use the current tick directly as
-- obtained from the 'ticks' function.
-- So we "rewind" it to the previous tick for the purpose of this display.
renderDutyCycle :: GameState -> Robot -> Widget Name
renderDutyCycle gs robot =
  withAttr dutyCycleAttr . str . flip (showFFloat (Just 1)) "%" $ dutyCyclePercentage
 where
  curTicks = gs ^. temporal . ticks
  window = robot ^. activityCounts . activityWindow

  -- Rewind to previous tick
  latestRobotTick = addTicks (-1) curTicks
  dutyCycleRatio = WC.getOccupancy latestRobotTick window

  dutyCycleAttr = safeIndex dutyCycleRatio meterAttributeNames

  dutyCyclePercentage :: Double
  dutyCyclePercentage = 100 * getValue dutyCycleRatio

robotsListWidget :: AppState -> Widget Name
robotsListWidget s = hCenter table
 where
  table =
    BT.renderTable
      . BT.columnBorders False
      . BT.setDefaultColAlignment BT.AlignCenter
      -- Inventory count is right aligned
      . BT.alignRight 4
      . BT.table
      $ map (padLeftRight 1) <$> (headers : robotsTable)
  headings =
    [ "Name"
    , "Age"
    , "Pos"
    , "Items"
    , "Status"
    , "Actns"
    , "Cmds"
    , "Cycles"
    , "Activity"
    , "Log"
    ]
  headers = withAttr robotAttr . txt <$> applyWhen cheat ("ID" :) headings
  robotsTable = mkRobotRow <$> robots
  mkRobotRow robot =
    applyWhen cheat (idWidget :) cells
   where
    cells =
      [ nameWidget
      , str ageStr
      , locWidget
      , padRight (Pad 1) (str $ show rInvCount)
      , statusWidget
      , str $ show $ robot ^. activityCounts . tangibleCommandCount
      , -- TODO(#1341): May want to expose the details of this histogram in
        -- a per-robot pop-up
        str . show . sum . M.elems $ robot ^. activityCounts . commandsHistogram
      , str $ show $ robot ^. activityCounts . lifetimeStepCount
      , renderDutyCycle (s ^. gameState) robot
      , txt rLog
      ]

    idWidget = str $ show $ robot ^. robotID
    nameWidget =
      hBox
        [ renderDisplay (robot ^. robotDisplay)
        , highlightSystem . txt $ " " <> robot ^. robotName
        ]

    highlightSystem = if robot ^. systemRobot then withAttr highlightAttr else id

    ageStr
      | age < 60 = show age <> "sec"
      | age < 3600 = show (age `div` 60) <> "min"
      | age < 3600 * 24 = show (age `div` 3600) <> "hour"
      | otherwise = show (age `div` 3600 * 24) <> "day"
     where
      TimeSpec createdAtSec _ = robot ^. robotCreatedAt
      TimeSpec nowSec _ = s ^. uiState . lastFrameTime
      age = nowSec - createdAtSec

    rInvCount = sum $ map fst . E.elems $ robot ^. robotEntity . entityInventory
    rLog
      | robot ^. robotLogUpdated = "x"
      | otherwise = " "

    locWidget = hBox [worldCell, str $ " " <> locStr]
     where
      rCoords = fmap W.locToCoords rLoc
      rLoc = robot ^. robotLocation
      worldCell =
        drawLoc
          (s ^. uiState)
          g
          rCoords
      locStr = renderCoordsString rLoc

    statusWidget = case robot ^. machine of
      Waiting {} -> txt "waiting"
      _
        | isActive robot -> withAttr notifAttr $ txt "busy"
        | otherwise -> withAttr greenAttr $ txt "idle"

  basePos :: Point V2 Double
  basePos = realToFrac <$> fromMaybe origin (g ^? baseRobot . robotLocation . planar)
  -- Keep the base and non system robot (e.g. no seed)
  isRelevant robot = robot ^. robotID == 0 || not (robot ^. systemRobot)
  -- Keep the robot that are less than 32 unit away from the base
  isNear robot = creative || distance (realToFrac <$> robot ^. robotLocation . planar) basePos < 32
  robots :: [Robot]
  robots =
    filter (\robot -> debugging || (isRelevant robot && isNear robot))
      . IM.elems
      $ g ^. robotMap
  creative = g ^. creativeMode
  cheat = s ^. uiState . uiCheatMode
  debugging = creative && cheat
  g = s ^. gameState

helpWidget :: Seed -> Maybe Port -> Widget Name
helpWidget theSeed mport =
  padTop (Pad 1) $
    (hBox . map (padLeftRight 2) $ [helpKeys, info])
      <=> padTop (Pad 1) (hCenter tips)
 where
  tips =
    vBox
      [ txt "Have questions? Want some tips? Check out:"
      , txt " "
      , txt $ "  - The Swarm wiki, " <> wikiUrl
      , txt "  - The #swarm IRC channel on Libera.Chat"
      ]
  info =
    vBox
      [ txt "Configuration"
      , txt " "
      , txt ("Seed: " <> into @Text (show theSeed))
      , txt ("Web server port: " <> maybe "none" (into @Text . show) mport)
      ]
  helpKeys =
    vBox
      [ txt "Keybindings"
      , txt " "
      , mkTable glKeyBindings
      ]
  mkTable =
    BT.renderTable
      . BT.surroundingBorder False
      . BT.rowBorders False
      . BT.table
      . map toRow
  toRow (k, v) = [padRight (Pad 1) $ txt k, padLeft (Pad 1) $ txt v]
  glKeyBindings =
    [ ("F1", "Help")
    , ("F2", "Robots list")
    , ("F3", "Available recipes")
    , ("F4", "Available commands")
    , ("F5", "Messages")
    , ("F6", "Structures")
    , ("Ctrl-g", "show goal")
    , ("Ctrl-p", "pause")
    , ("Ctrl-o", "single step")
    , ("Ctrl-z", "decrease speed")
    , ("Ctrl-w", "increase speed")
    , ("Ctrl-q", "quit the current scenario")
    , ("Ctrl-s", "collapse/expand REPL")
    , ("Meta-h", "hide robots for 2s")
    , ("Meta-w", "focus on the world map")
    , ("Meta-e", "focus on the robot inventory")
    , ("Meta-r", "focus on the REPL")
    , ("Meta-t", "focus on the info panel")
    ]

data NotificationList = RecipeList | MessageList

availableListWidget :: GameState -> NotificationList -> Widget Name
availableListWidget gs nl = padTop (Pad 1) $ vBox widgetList
 where
  widgetList = case nl of
    RecipeList -> mkAvailableList gs (discovery . availableRecipes) renderRecipe
    MessageList -> messagesWidget gs
  renderRecipe = padLeftRight 18 . drawRecipe Nothing (fromMaybe E.empty inv)
  inv = gs ^? to focusedRobot . _Just . robotInventory

mkAvailableList :: GameState -> Lens' GameState (Notifications a) -> (a -> Widget Name) -> [Widget Name]
mkAvailableList gs notifLens notifRender = map padRender news <> notifSep <> map padRender knowns
 where
  padRender = padBottom (Pad 1) . notifRender
  count = gs ^. notifLens . notificationsCount
  (news, knowns) = splitAt count (gs ^. notifLens . notificationsContent)
  notifSep
    | count > 0 && not (null knowns) =
        [ padBottom (Pad 1) (withAttr redAttr $ hBorderWithLabel (padLeftRight 1 (txt "new↑")))
        ]
    | otherwise = []

commandsListWidget :: GameState -> Widget Name
commandsListWidget gs =
  hCenter $
    vBox
      [ table
      , padTop (Pad 1) $ txt "For the full list of available commands see the Wiki at:"
      , txt wikiCheatSheet
      ]
 where
  commands = gs ^. discovery . availableCommands . notificationsContent
  table =
    BT.renderTable
      . BT.surroundingBorder False
      . BT.columnBorders False
      . BT.rowBorders False
      . BT.setDefaultColAlignment BT.AlignLeft
      . BT.alignRight 0
      . BT.table
      $ headers : commandsTable
  headers =
    withAttr robotAttr
      <$> [ txt "command name"
          , txt " : type"
          , txt "Enabled by"
          ]

  commandsTable = mkCmdRow <$> commands
  mkCmdRow cmd =
    map
      (padTop $ Pad 1)
      [ txt $ syntax $ constInfo cmd
      , padRight (Pad 2) . withAttr magentaAttr . txt $ " : " <> prettyTextLine (inferConst cmd)
      , listDevices cmd
      ]

  base = gs ^? baseRobot
  entsByCap = case base of
    Just r ->
      M.map NE.toList $
        entitiesByCapability $
          (r ^. equippedDevices) `union` (r ^. robotInventory)
    Nothing -> mempty

  listDevices cmd = vBox $ map drawLabelledEntityName providerDevices
   where
    providerDevices =
      concatMap (flip (M.findWithDefault []) entsByCap) $
        maybeToList $
          constCaps cmd

-- | Generate a pop-up widget to display the description of an entity.
descriptionWidget :: AppState -> Entity -> Widget Name
descriptionWidget s e = padLeftRight 1 (explainEntry s e)

-- | Draw a widget with messages to the current robot.
messagesWidget :: GameState -> [Widget Name]
messagesWidget gs = widgetList
 where
  widgetList = focusNewest . map drawLogEntry' $ gs ^. messageNotifications . notificationsContent
  focusNewest = if gs ^. temporal . paused then id else over _last visible
  drawLogEntry' e =
    withAttr (colorLogs e) $
      hBox
        [ fromMaybe (txt "") $ maybeDrawTime (e ^. leTime) True gs
        , padLeft (Pad 2) . txt $ brackets $ e ^. leName
        , padLeft (Pad 1) . txt2 $ e ^. leText
        ]
  txt2 = txtWrapWith indent2

colorLogs :: LogEntry -> AttrName
colorLogs e = case e ^. leSource of
  SystemLog -> colorSeverity (e ^. leSeverity)
  RobotLog rls rid _loc -> case rls of
    Said -> robotColor rid
    Logged -> notifAttr
    RobotError -> colorSeverity (e ^. leSeverity)
 where
  -- color each robot message with different color of the world
  robotColor = indexWrapNonEmpty worldAttributeNames

colorSeverity :: Severity -> AttrName
colorSeverity = \case
  Info -> infoAttr
  Debug -> dimAttr
  Warning -> yellowAttr
  Error -> redAttr
  Critical -> redAttr

-- | Draw the F-key modal menu. This is displayed in the top left world corner.
drawModalMenu :: AppState -> Widget Name
drawModalMenu s = vLimit 1 . hBox $ map (padLeftRight 1 . drawKeyCmd) globalKeyCmds
 where
  notificationKey :: Getter GameState (Notifications a) -> Text -> Text -> Maybe (KeyHighlight, Text, Text)
  notificationKey notifLens key name
    | null (s ^. gameState . notifLens . notificationsContent) = Nothing
    | otherwise =
        let highlight
              | s ^. gameState . notifLens . notificationsCount > 0 = Alert
              | otherwise = NoHighlight
         in Just (highlight, key, name)

  -- Hides this key if the recognizable structure list is empty
  structuresKey =
    if null $ s ^. gameState . discovery . structureRecognition . automatons . definitions
      then Nothing
      else Just (NoHighlight, "F6", "Structures")

  globalKeyCmds =
    catMaybes
      [ Just (NoHighlight, "F1", "Help")
      , Just (NoHighlight, "F2", "Robots")
      , notificationKey (discovery . availableRecipes) "F3" "Recipes"
      , notificationKey (discovery . availableCommands) "F4" "Commands"
      , notificationKey messageNotifications "F5" "Messages"
      , structuresKey
      ]

-- | Draw a menu explaining what key commands are available for the
--   current panel.  This menu is displayed as one or two lines in
--   between the world panel and the REPL.
--
-- This excludes the F-key modals that are shown elsewhere.
drawKeyMenu :: AppState -> Widget Name
drawKeyMenu s =
  vLimit 2 $
    hBox
      [ padBottom Max $
          vBox
            [ mkCmdRow globalKeyCmds
            , padLeft (Pad 2) contextCmds
            ]
      , gameModeWidget
      ]
 where
  mkCmdRow = hBox . map drawPaddedCmd
  drawPaddedCmd = padLeftRight 1 . drawKeyCmd
  contextCmds
    | ctrlMode == Handling = txt $ fromMaybe "" (s ^? gameState . gameControls . inputHandler . _Just . _1)
    | otherwise = mkCmdRow focusedPanelCmds
  focusedPanelCmds =
    map highlightKeyCmds
      . keyCmdsFor
      . focusGetCurrent
      . view (uiState . uiFocusRing)
      $ s

  isReplWorking = s ^. gameState . gameControls . replWorking
  isPaused = s ^. gameState . temporal . paused
  hasDebug = fromMaybe creative $ s ^? gameState . to focusedRobot . _Just . robotCapabilities . Lens.contains CDebug
  viewingBase = (s ^. gameState . viewCenterRule) == VCRobot 0
  creative = s ^. gameState . creativeMode
  cheat = s ^. uiState . uiCheatMode
  goal = hasAnythingToShow $ s ^. uiState . uiGoal . goalsContent
  showZero = s ^. uiState . uiShowZero
  inventorySort = s ^. uiState . uiInventorySort
  inventorySearch = s ^. uiState . uiInventorySearch
  ctrlMode = s ^. uiState . uiREPL . replControlMode
  canScroll = creative || (s ^. gameState . landscape . worldScrollable)
  handlerInstalled = isJust (s ^. gameState . gameControls . inputHandler)

  renderPilotModeSwitch :: ReplControlMode -> T.Text
  renderPilotModeSwitch = \case
    Piloting -> "REPL"
    _ -> "pilot"

  renderHandlerModeSwitch :: ReplControlMode -> T.Text
  renderHandlerModeSwitch = \case
    Handling -> "REPL"
    _ -> "key handler"

  gameModeWidget =
    padLeft Max
      . padLeftRight 1
      . txt
      . (<> " mode")
      $ case creative of
        False -> "Classic"
        True -> "Creative"
  globalKeyCmds =
    catMaybes
      [ may goal (NoHighlight, "^g", "goal")
      , may cheat (NoHighlight, "^v", "creative")
      , may cheat (NoHighlight, "^e", "editor")
      , Just (NoHighlight, "^p", if isPaused then "unpause" else "pause")
      , may isPaused (NoHighlight, "^o", "step")
      , may (isPaused && hasDebug) (if s ^. uiState . uiShowDebug then Alert else NoHighlight, "M-d", "debug")
      , Just (NoHighlight, "^zx", "speed")
      , Just (NoHighlight, "M-,", if s ^. uiState . uiShowREPL then "hide REPL" else "show REPL")
      , Just (if s ^. uiState . uiShowRobots then NoHighlight else Alert, "M-h", "hide robots")
      ]
  may b = if b then Just else const Nothing

  highlightKeyCmds (k, n) = (PanelSpecific, k, n)

  keyCmdsFor (Just (FocusablePanel WorldEditorPanel)) =
    [("^s", "save map")]
  keyCmdsFor (Just (FocusablePanel REPLPanel)) =
    [ ("↓↑", "history")
    ]
      ++ [("Enter", "execute") | not isReplWorking]
      ++ [("^c", "cancel") | isReplWorking]
      ++ [("M-p", renderPilotModeSwitch ctrlMode) | creative]
      ++ [("M-k", renderHandlerModeSwitch ctrlMode) | handlerInstalled]
      ++ [("PgUp/Dn", "scroll")]
  keyCmdsFor (Just (FocusablePanel WorldPanel)) =
    [ ("←↓↑→ / hjkl", "scroll") | canScroll
    ]
      ++ [("c", "recenter") | not viewingBase]
      ++ [("f", "FPS")]
  keyCmdsFor (Just (FocusablePanel RobotPanel)) =
    ("Enter", "pop out")
      : if isJust inventorySearch
        then [("Esc", "exit search")]
        else
          [ ("m", "make")
          , ("0", (if showZero then "hide" else "show") <> " 0")
          , (":/;", T.unwords ["Sort:", renderSortMethod inventorySort])
          , ("/", "search")
          ]
  keyCmdsFor (Just (FocusablePanel InfoPanel)) = []
  keyCmdsFor _ = []

data KeyHighlight = NoHighlight | Alert | PanelSpecific

-- | Draw a single key command in the menu.
drawKeyCmd :: (KeyHighlight, Text, Text) -> Widget Name
drawKeyCmd (h, key, cmd) =
  hBox
    [ withAttr attr (txt $ brackets key)
    , txt cmd
    ]
 where
  attr = case h of
    NoHighlight -> defAttr
    Alert -> notifAttr
    PanelSpecific -> highlightAttr

------------------------------------------------------------
-- World panel
------------------------------------------------------------

worldWidget ::
  (Cosmic W.Coords -> Widget n) ->
  -- | view center
  Cosmic Location ->
  Widget n
worldWidget renderCoord gameViewCenter = Widget Fixed Fixed $
  do
    ctx <- getContext
    let w = ctx ^. availWidthL
        h = ctx ^. availHeightL
        vr = viewingRegion gameViewCenter (fromIntegral w, fromIntegral h)
        ixs = range $ vr ^. planar
    render . vBox . map hBox . chunksOf w . map (renderCoord . Cosmic (vr ^. subworld)) $ ixs

-- | Draw the current world view.
drawWorldPane :: UIState -> GameState -> Widget Name
drawWorldPane ui g =
  center
    . cached WorldCache
    . reportExtent WorldExtent
    -- Set the clickable request after the extent to play nice with the cache
    . clickable (FocusablePanel WorldPanel)
    $ worldWidget renderCoord (g ^. viewCenter)
 where
  renderCoord = drawLoc ui g

------------------------------------------------------------
-- Robot inventory panel
------------------------------------------------------------

-- | Draw info about the currently focused robot, such as its name,
--   position, orientation, and inventory, as long as it is not too
--   far away.
drawRobotPanel :: AppState -> Widget Name
drawRobotPanel s
  -- If the focused robot is too far away to communicate, just leave the panel blank.
  -- There should be no way to tell the difference between a robot that is too far
  -- away and a robot that does not exist.
  | Just r <- s ^. gameState . to focusedRobot
  , Just (_, lst) <- s ^. uiState . uiInventory =
      let drawClickableItem pos selb = clickable (InventoryListItem pos) . drawItem (lst ^. BL.listSelectedL) pos selb
          row =
            [ txt (r ^. robotName)
            , padLeft (Pad 2) . str . renderCoordsString $ r ^. robotLocation
            , padLeft (Pad 2) $ renderDisplay (r ^. robotDisplay)
            ]
       in padBottom Max $
            vBox
              [ hCenter $ hBox row
              , withLeftPaddedVScrollBars . padLeft (Pad 1) . padTop (Pad 1) $
                  BL.renderListWithIndex drawClickableItem True lst
              ]
  | otherwise = blank

blank :: Widget Name
blank = padRight Max . padBottom Max $ str " "

-- | Draw an inventory entry.
drawItem ::
  -- | The index of the currently selected inventory entry
  Maybe Int ->
  -- | The index of the entry we are drawing
  Int ->
  -- | Whether this entry is selected; we can ignore this
  --   because it will automatically have a special attribute
  --   applied to it.
  Bool ->
  -- | The entry to draw.
  InventoryListEntry ->
  Widget Name
drawItem sel i _ (Separator l) =
  -- Make sure a separator right before the focused element is
  -- visible. Otherwise, when a separator occurs as the very first
  -- element of the list, once it scrolls off the top of the viewport
  -- it will never become visible again.
  -- See https://github.com/jtdaugherty/brick/issues/336#issuecomment-921220025
  (if sel == Just (i + 1) then visible else id) $ hBorderWithLabel (txt l)
drawItem _ _ _ (InventoryEntry n e) = drawLabelledEntityName e <+> showCount n
 where
  showCount = padLeft Max . str . show
drawItem _ _ _ (EquippedEntry e) = drawLabelledEntityName e <+> padLeft Max (str " ")

------------------------------------------------------------
-- Info panel
------------------------------------------------------------

-- | Draw the info panel in the bottom-left corner, which shows info
--   about the currently focused inventory item.
drawInfoPanel :: AppState -> Widget Name
drawInfoPanel s
  | Just Far <- s ^. gameState . to focusedRange = blank
  | otherwise =
      withVScrollBars OnRight
        . viewport InfoViewport Vertical
        . padLeftRight 1
        $ explainFocusedItem s

-- | Display info about the currently focused inventory entity,
--   such as its description and relevant recipes.
explainFocusedItem :: AppState -> Widget Name
explainFocusedItem s = case focusedItem s of
  Just (InventoryEntry _ e) -> explainEntry s e
  Just (EquippedEntry e) -> explainEntry s e
  _ -> txt " "

explainEntry :: AppState -> Entity -> Widget Name
explainEntry s e =
  vBox $
    [ displayProperties $ Set.toList (e ^. entityProperties)
    , drawMarkdown (e ^. entityDescription)
    , explainRecipes s e
    ]
      <> [drawRobotMachine s False | e ^. entityCapabilities . Lens.contains CDebug]
      <> [drawRobotLog s | e ^. entityCapabilities . Lens.contains CLog]

displayProperties :: [EntityProperty] -> Widget Name
displayProperties = displayList . mapMaybe showProperty
 where
  showProperty Growable = Just "growing"
  showProperty Combustible = Just "combustible"
  showProperty Infinite = Just "infinite"
  showProperty Liquid = Just "liquid"
  showProperty Unwalkable = Just "blocking"
  showProperty Opaque = Just "opaque"
  -- Most things are portable so we don't show that.
  showProperty Portable = Nothing
  -- 'Known' is just a technical detail of how we handle some entities
  -- in challenge scenarios and not really something the player needs
  -- to know.
  showProperty Known = Nothing

  displayList [] = emptyWidget
  displayList ps =
    vBox
      [ hBox . L.intersperse (txt ", ") . map (withAttr robotAttr . txt) $ ps
      , txt " "
      ]

explainRecipes :: AppState -> Entity -> Widget Name
explainRecipes s e
  | null recipes = emptyWidget
  | otherwise =
      vBox
        [ padBottom (Pad 1) (hBorderWithLabel (txt "Recipes"))
        , padLeftRight 2
            . hCenter
            . vBox
            $ map (hLimit widthLimit . padBottom (Pad 1) . drawRecipe (Just e) inv) recipes
        ]
 where
  recipes = recipesWith s e

  inv = fromMaybe E.empty $ s ^? gameState . to focusedRobot . _Just . robotInventory

  width (n, ingr) =
    length (show n) + 1 + maximum0 (map T.length . T.words $ ingr ^. entityName)

  maxInputWidth =
    fromMaybe 0 $
      maximumOf (traverse . recipeInputs . traverse . to width) recipes
  maxOutputWidth =
    fromMaybe 0 $
      maximumOf (traverse . recipeOutputs . traverse . to width) recipes
  widthLimit = 2 * max maxInputWidth maxOutputWidth + 11

-- | Return all recipes that involve a given entity.
recipesWith :: AppState -> Entity -> [Recipe Entity]
recipesWith s e =
  let getRecipes select = recipesFor (s ^. gameState . recipesInfo . select) e
   in -- The order here is chosen intentionally.  See https://github.com/swarm-game/swarm/issues/418.
      --
      --   1. Recipes where the entity is an input --- these should go
      --     first since the first thing you will want to know when you
      --     obtain a new entity is what you can do with it.
      --
      --   2. Recipes where it serves as a catalyst --- for the same reason.
      --
      --   3. Recipes where it is an output --- these should go last,
      --      since if you have it, you probably already figured out how
      --      to make it.
      L.nub $
        concat
          [ getRecipes recipesIn
          , getRecipes recipesCat
          , getRecipes recipesOut
          ]

-- | Draw an ASCII art representation of a recipe.  For now, the
--   weight is not shown.
drawRecipe :: Maybe Entity -> Inventory -> Recipe Entity -> Widget Name
drawRecipe me inv (Recipe ins outs reqs time _weight) =
  vBox
    -- any requirements (e.g. furnace) go on top.
    [ hCenter $ drawReqs reqs
    , -- then we draw inputs, a connector, and outputs.
      hBox
        [ vBox (zipWith drawIn [0 ..] (ins <> times))
        , connector
        , vBox (zipWith drawOut [0 ..] outs)
        ]
    ]
 where
  -- The connector is either just a horizontal line ─────
  -- or, if there are requirements, a horizontal line with
  -- a vertical piece coming out of the center, ──┴── .
  connector
    | null reqs = hLimit 5 hBorder
    | otherwise =
        hBox
          [ hLimit 2 hBorder
          , joinableBorder (Edges True False True True)
          , hLimit 2 hBorder
          ]
  inLen = length ins + length times
  outLen = length outs
  times = [(fromIntegral time, timeE) | time /= 1]

  -- Draw inputs and outputs.
  drawIn, drawOut :: Int -> (Count, Entity) -> Widget Name
  drawIn i (n, ingr) =
    hBox
      [ padRight (Pad 1) $ str (show n) -- how many?
      , fmtEntityName missing ingr -- name of the input
      , padLeft (Pad 1) $ -- a connecting line:   ─────┬
          hBorder
            <+> ( joinableBorder (Edges (i /= 0) (i /= inLen - 1) True False) -- ...maybe plus vert ext:   │
                    <=> if i /= inLen - 1
                      then vLimit (subtract 1 . length . T.words $ ingr ^. entityName) vBorder
                      else emptyWidget
                )
      ]
   where
    missing = E.lookup ingr inv < n

  drawOut i (n, ingr) =
    hBox
      [ padRight (Pad 1) $
          ( joinableBorder (Edges (i /= 0) (i /= outLen - 1) False True)
              <=> if i /= outLen - 1
                then vLimit (subtract 1 . length . T.words $ ingr ^. entityName) vBorder
                else emptyWidget
          )
            <+> hBorder
      , fmtEntityName False ingr
      , padLeft (Pad 1) $ str (show n)
      ]

  -- If it's the focused entity, draw it highlighted.
  -- If the robot doesn't have any, draw it in red.
  fmtEntityName missing ingr
    | Just ingr == me = withAttr highlightAttr $ txtLines nm
    | ingr == timeE = withAttr yellowAttr $ txtLines nm
    | missing = withAttr invalidFormInputAttr $ txtLines nm
    | otherwise = txtLines nm
   where
    -- Split up multi-word names, one line per word
    nm = ingr ^. entityName
    txtLines = vBox . map txt . T.words

-- | Ad-hoc entity to represent time - only used in recipe drawing
timeE :: Entity
timeE = mkEntity (defaultEntityDisplay '.') "ticks" mempty [] []

drawReqs :: IngredientList Entity -> Widget Name
drawReqs = vBox . map (hCenter . drawReq)
 where
  drawReq (1, e) = txt $ e ^. entityName
  drawReq (n, e) = str (show n) <+> txt " " <+> txt (e ^. entityName)

indent2 :: WrapSettings
indent2 = defaultWrapSettings {fillStrategy = FillIndent 2}

drawRobotLog :: AppState -> Widget Name
drawRobotLog s =
  vBox
    [ padBottom (Pad 1) (hBorderWithLabel (txt "Log"))
    , vBox . F.toList . imap drawEntry $ logEntries
    ]
 where
  logEntries = s ^. gameState . to focusedRobot . _Just . robotLog

  rid = s ^? gameState . to focusedRobot . _Just . robotID
  n = Seq.length logEntries

  allMe = all me logEntries
  me le = case le ^. leSource of
    RobotLog _ i _ -> Just i == rid
    _ -> False

  drawEntry i e =
    (if i == n - 1 && s ^. uiState . uiScrollToEnd then visible else id) $
      drawLogEntry (not allMe) e

-- | Show the 'CESK' machine of focused robot. Puts a separator above.
drawRobotMachine :: AppState -> Bool -> Widget Name
drawRobotMachine s showName = case s ^. gameState . to focusedRobot of
  Nothing -> machineLine "no selected robot"
  Just r ->
    vBox
      [ machineLine $ r ^. robotName <> "#" <> r ^. robotID . to tshow
      , txt $ r ^. machine . to prettyText
      ]
 where
  tshow = T.pack . show
  hLine t = padBottom (Pad 1) (hBorderWithLabel (txt t))
  machineLine r = hLine $ if showName then "Machine [" <> r <> "]" else "Machine"

-- | Draw one log entry with an optional robot name first.
drawLogEntry :: Bool -> LogEntry -> Widget a
drawLogEntry addName e =
  withAttr (colorLogs e) . txtWrapWith indent2 $
    if addName then name else t
 where
  t = e ^. leText
  name =
    "["
      <> view leName e
      <> "] "
      <> case e ^. leSource of
        RobotLog Said _ _ -> "said " <> quote t
        _ -> t

------------------------------------------------------------
-- REPL panel
------------------------------------------------------------

-- | Turn the repl prompt into a decorator for the form
replPromptAsWidget :: Text -> REPLPrompt -> Widget Name
replPromptAsWidget _ (CmdPrompt _) = txt "> "
replPromptAsWidget t (SearchPrompt rh) =
  case lastEntry t rh of
    Nothing -> txt "[nothing found] "
    Just lastentry
      | T.null t -> txt "[find] "
      | otherwise -> txt $ "[found: \"" <> lastentry <> "\"] "

renderREPLPrompt :: FocusRing Name -> REPLState -> Widget Name
renderREPLPrompt focus theRepl = ps1 <+> replE
 where
  prompt = theRepl ^. replPromptType
  replEditor = theRepl ^. replPromptEditor
  color = if theRepl ^. replValid then id else withAttr redAttr
  ps1 = replPromptAsWidget (T.concat $ getEditContents replEditor) prompt
  replE =
    renderEditor
      (color . vBox . map txt)
      (focusGetCurrent focus `elem` [Nothing, Just (FocusablePanel REPLPanel), Just REPLInput])
      replEditor

-- | Draw the REPL.
drawREPL :: AppState -> Widget Name
drawREPL s =
  vBox
    [ withLeftPaddedVScrollBars
        . viewport REPLViewport Vertical
        . vBox
        $ [cached REPLHistoryCache (vBox history), currentPrompt]
    , vBox mayDebug
    ]
 where
  -- rendered history lines fitting above REPL prompt
  history :: [Widget n]
  history = map fmt . toList . getSessionREPLHistoryItems $ theRepl ^. replHistory
  currentPrompt :: Widget Name
  currentPrompt = case (isActive <$> base, theRepl ^. replControlMode) of
    (_, Handling) -> padRight Max $ txt "[key handler running, M-k to toggle]"
    (Just False, _) -> renderREPLPrompt (s ^. uiState . uiFocusRing) theRepl
    _running -> padRight Max $ txt "..."
  theRepl = s ^. uiState . uiREPL
  base = s ^. gameState . robotMap . at 0
  fmt (REPLEntry e) = txt $ "> " <> e
  fmt (REPLOutput t) = txt t
  fmt (REPLError t) = txtWrapWith indent2 {preserveIndentation = True} t
  mayDebug = [drawRobotMachine s True | s ^. uiState . uiShowDebug]

------------------------------------------------------------
-- Utility
------------------------------------------------------------

-- See https://github.com/jtdaugherty/brick/discussions/484
withLeftPaddedVScrollBars :: Widget n -> Widget n
withLeftPaddedVScrollBars =
  withVScrollBarRenderer (addLeftSpacing verticalScrollbarRenderer)
    . withVScrollBars OnRight
 where
  addLeftSpacing :: VScrollbarRenderer n -> VScrollbarRenderer n
  addLeftSpacing r =
    r
      { scrollbarWidthAllocation = 2
      , renderVScrollbar = hLimit 1 $ renderVScrollbar r
      , renderVScrollbarTrough = hLimit 1 $ renderVScrollbarTrough r
      }
