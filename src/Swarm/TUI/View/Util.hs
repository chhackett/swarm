{-# LANGUAGE OverloadedStrings #-}

-- |
-- SPDX-License-Identifier: BSD-3-Clause
module Swarm.TUI.View.Util where

import Brick hiding (Direction, Location)
import Brick.Widgets.Dialog
import Brick.Widgets.List qualified as BL
import Control.Lens hiding (Const, from)
import Control.Monad.Reader (withReaderT)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as M
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Graphics.Vty qualified as V
import Swarm.Game.Entity as E
import Swarm.Game.Location
import Swarm.Game.Scenario (scenarioName)
import Swarm.Game.ScenarioInfo (scenarioItemName)
import Swarm.Game.State
import Swarm.Game.Terrain
import Swarm.Language.Pretty (prettyText)
import Swarm.Language.Syntax (Syntax)
import Swarm.Language.Text.Markdown qualified as Markdown
import Swarm.Language.Types (Polytype)
import Swarm.TUI.Model
import Swarm.TUI.Model.UI
import Swarm.TUI.View.Attribute.Attr
import Swarm.TUI.View.CellDisplay
import Swarm.Util (listEnums)
import Witch (from, into)

-- | Generate a fresh modal window of the requested type.
generateModal :: AppState -> ModalType -> Modal
generateModal s mt = Modal mt (dialog (Just $ str title) buttons (maxModalWindowWidth `min` requiredWidth))
 where
  currentScenario = s ^. uiState . scenarioRef
  currentSeed = s ^. gameState . seed
  haltingMessage = case s ^. uiState . uiMenu of
    NoMenu -> Just "Quit"
    _ -> Nothing
  descriptionWidth = 100
  helpWidth = 80
  (title, buttons, requiredWidth) =
    case mt of
      HelpModal -> (" Help ", Nothing, helpWidth)
      RobotsModal -> ("Robots", Nothing, descriptionWidth)
      RecipesModal -> ("Available Recipes", Nothing, descriptionWidth)
      CommandsModal -> ("Available Commands", Nothing, descriptionWidth)
      MessagesModal -> ("Messages", Nothing, descriptionWidth)
      StructuresModal -> ("Buildable Structures", Nothing, descriptionWidth)
      ScenarioEndModal WinModal ->
        let nextMsg = "Next challenge!"
            stopMsg = fromMaybe "Return to the menu" haltingMessage
            continueMsg = "Keep playing"
         in ( ""
            , Just
                ( Button NextButton
                , [ (nextMsg, Button NextButton, Next scene)
                  | Just scene <- [nextScenario (s ^. uiState . uiMenu)]
                  ]
                    ++ [ (stopMsg, Button QuitButton, QuitAction)
                       , (continueMsg, Button KeepPlayingButton, KeepPlaying)
                       ]
                )
            , sum (map length [nextMsg, stopMsg, continueMsg]) + 32
            )
      ScenarioEndModal LoseModal ->
        let stopMsg = fromMaybe "Return to the menu" haltingMessage
            continueMsg = "Keep playing"
            maybeStartOver = do
              cs <- currentScenario
              return ("Start over", Button StartOverButton, StartOver currentSeed cs)
         in ( ""
            , Just
                ( Button QuitButton
                , catMaybes
                    [ Just (stopMsg, Button QuitButton, QuitAction)
                    , maybeStartOver
                    , Just (continueMsg, Button KeepPlayingButton, KeepPlaying)
                    ]
                )
            , sum (map length [stopMsg, continueMsg]) + 32
            )
      DescriptionModal e -> (descriptionTitle e, Nothing, descriptionWidth)
      QuitModal ->
        let stopMsg = fromMaybe ("Quit to" ++ maybe "" (" " ++) (into @String <$> curMenuName s) ++ " menu") haltingMessage
            maybeStartOver = do
              cs <- currentScenario
              return ("Start over", Button StartOverButton, StartOver currentSeed cs)
         in ( ""
            , Just
                ( Button CancelButton
                , catMaybes
                    [ Just ("Keep playing", Button CancelButton, Cancel)
                    , maybeStartOver
                    , Just (stopMsg, Button QuitButton, QuitAction)
                    ]
                )
            , T.length (quitMsg (s ^. uiState . uiMenu)) + 4
            )
      GoalModal ->
        let goalModalTitle = case currentScenario of
              Nothing -> "Goal"
              Just (scenario, _) -> scenario ^. scenarioName
         in (" " <> T.unpack goalModalTitle <> " ", Nothing, descriptionWidth)
      KeepPlayingModal -> ("", Just (Button CancelButton, [("OK", Button CancelButton, Cancel)]), 80)
      TerrainPaletteModal -> ("Terrain", Nothing, w)
       where
        wordLength = maximum $ map (length . show) (listEnums :: [TerrainType])
        w = wordLength + 6
      EntityPaletteModal -> ("Entity", Nothing, 30)

-- | Render the type of the current REPL input to be shown to the user.
drawType :: Polytype -> Widget Name
drawType = withAttr infoAttr . padLeftRight 1 . txt . prettyText

-- | Draw markdown document with simple code/bold/italic attributes.
--
-- TODO: #574 Code blocks should probably be handled separately.
drawMarkdown :: Markdown.Document Syntax -> Widget Name
drawMarkdown d = do
  Widget Greedy Fixed $ do
    ctx <- getContext
    let w = ctx ^. availWidthL
    let docLines = Markdown.chunksOf w . Markdown.toStream <$> Markdown.paragraphs d
    render . layoutParagraphs $ vBox . map (hBox . map mTxt) <$> docLines
 where
  mTxt = \case
    Markdown.TextNode as t -> foldr applyAttr (txt t) as
    Markdown.CodeNode t -> withAttr highlightAttr $ txt t
    Markdown.RawNode f t -> withAttr (rawAttr f) $ txt t
  applyAttr a = withAttr $ case a of
    Markdown.Strong -> boldAttr
    Markdown.Emphasis -> italicAttr
  rawAttr = \case
    "entity" -> greenAttr
    "type" -> magentaAttr
    _snippet -> highlightAttr -- same as plain code

drawLabeledTerrainSwatch :: TerrainType -> Widget Name
drawLabeledTerrainSwatch a =
  tile <+> str materialName
 where
  tile = padRight (Pad 1) $ renderDisplay $ terrainMap M.! a
  materialName = init $ show a

descriptionTitle :: Entity -> String
descriptionTitle e = " " ++ from @Text (e ^. entityName) ++ " "

-- | Width cap for modal and error message windows
maxModalWindowWidth :: Int
maxModalWindowWidth = 500

-- | Get the name of the current New Game menu.
curMenuName :: AppState -> Maybe Text
curMenuName s = case s ^. uiState . uiMenu of
  NewGameMenu (_ :| (parentMenu : _)) ->
    Just (parentMenu ^. BL.listSelectedElementL . to scenarioItemName)
  NewGameMenu _ -> Just "Scenarios"
  _ -> Nothing

quitMsg :: Menu -> Text
quitMsg m = "Are you sure you want to " <> quitAction <> "? All progress on this scenario will be lost!"
 where
  quitAction = case m of
    NoMenu -> "quit"
    _ -> "return to the menu"

locationToString :: Location -> String
locationToString (Location x y) =
  unwords $ map show [x, y]

-- | Display a list of text-wrapped paragraphs with one blank line after each.
displayParagraphs :: [Text] -> Widget Name
displayParagraphs = layoutParagraphs . map txtWrap

-- | Display a list of paragraphs with one blank line after each.
--
-- For the common case of `[Text]` use 'displayParagraphs'.
layoutParagraphs :: [Widget Name] -> Widget Name
layoutParagraphs ps = vBox $ padBottom (Pad 1) <$> ps

data EllipsisSide = Beginning | End

withEllipsis :: EllipsisSide -> Text -> Widget Name
withEllipsis side t =
  Widget Greedy Fixed $ do
    ctx <- getContext
    let w = ctx ^. availWidthL
        ellipsis = T.replicate 3 $ T.singleton '.'
        tLength = T.length t
        newText =
          if tLength > w
            then case side of
              Beginning -> ellipsis <> T.drop (w - T.length ellipsis) t
              End -> T.take (w - T.length ellipsis) t <> ellipsis
            else t
    render $ txt newText

-- | Make a widget scrolling if it is bigger than the available
--   vertical space.  Thanks to jtdaugherty for this code.
maybeScroll :: (Ord n, Show n) => n -> Widget n -> Widget n
maybeScroll vpName contents =
  Widget Greedy Greedy $ do
    ctx <- getContext
    result <- withReaderT (availHeightL .~ 10000) (render contents)
    if V.imageHeight (result ^. imageL) <= ctx ^. availHeightL
      then return result
      else
        render
          . withVScrollBars OnRight
          . viewport vpName Vertical
          . Widget Fixed Fixed
          $ return result

-- | Draw the name of an entity, labelled with its visual
--   representation as a cell in the world.
drawLabelledEntityName :: Entity -> Widget n
drawLabelledEntityName e =
  hBox
    [ padRight (Pad 2) (renderDisplay (e ^. entityDisplay))
    , txt (e ^. entityName)
    ]
