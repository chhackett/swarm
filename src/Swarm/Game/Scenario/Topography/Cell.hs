{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- SPDX-License-Identifier: BSD-3-Clause
module Swarm.Game.Scenario.Topography.Cell (
  PCell (..),
  Cell,
  AugmentedCell (..),
  CellPaintDisplay,
) where

import Control.Lens hiding (from, (.=), (<.>))
import Control.Monad.Extra (mapMaybeM)
import Data.List.NonEmpty qualified as NE
import Data.Maybe (catMaybes, listToMaybe)
import Data.Text (Text)
import Data.Vector qualified as V
import Data.Yaml as Y
import Swarm.Game.Entity hiding (empty)
import Swarm.Game.Scenario.RobotLookup
import Swarm.Game.Scenario.Topography.EntityFacade
import Swarm.Game.Scenario.Topography.Navigation.Waypoint (WaypointConfig)
import Swarm.Game.Terrain
import Swarm.Util.Erasable (Erasable (..))
import Swarm.Util.Yaml

------------------------------------------------------------
-- World cells
------------------------------------------------------------

-- | A single cell in a world map, which contains a terrain value,
--   and optionally an entity and robot.
--   It is parameterized on the 'Entity' type to facilitate less
--   stateful versions of the 'Entity' type in rendering scenario data.
data PCell e = Cell
  { cellTerrain :: TerrainType
  , cellEntity :: Erasable e
  , cellRobots :: [IndexedTRobot]
  }
  deriving (Eq, Show)

-- | A single cell in a world map, which contains a terrain value,
--   and optionally an entity and robot.
type Cell = PCell Entity

-- | Supplements a cell with waypoint information
data AugmentedCell e = AugmentedCell
  { waypointCfg :: Maybe WaypointConfig
  , standardCell :: PCell e
  }
  deriving (Eq, Show)

-- | Re-usable serialization for variants of 'PCell'
mkPCellJson :: ToJSON b => (Erasable a -> Maybe b) -> PCell a -> Value
mkPCellJson modifier x =
  toJSON $
    catMaybes
      [ Just . toJSON . getTerrainWord $ cellTerrain x
      , fmap toJSON . modifier $ cellEntity x
      , listToMaybe []
      ]

instance ToJSON Cell where
  toJSON = mkPCellJson $ \case
    EErase -> Just "erase"
    ENothing -> Nothing
    EJust e -> Just (e ^. entityName)

instance FromJSONE (EntityMap, RobotMap) Cell where
  parseJSONE = withArrayE "tuple" $ \v -> do
    let tupRaw = V.toList v
    tup <- case NE.nonEmpty tupRaw of
      Nothing -> fail "palette entry must have nonzero length (terrain, optional entity and then robots if any)"
      Just x -> return x

    terr <- liftE $ parseJSON (NE.head tup)

    ent <- case tup ^? ix 1 of
      Nothing -> return ENothing
      Just e -> do
        meName <- liftE $ parseJSON @(Maybe Text) e
        case meName of
          Nothing -> return ENothing
          Just "erase" -> return EErase
          Just name -> fmap EJust . localE fst $ getEntity name

    let name2rob r = do
          mrName <- liftE $ parseJSON @(Maybe RobotName) r
          traverse (localE snd . getRobot) mrName

    robs <- mapMaybeM name2rob (drop 2 tupRaw)

    return $ Cell terr ent robs

-- | Parse a tuple such as @[grass, rock, base]@ into a 'Cell'.  The
--   entity and robot, if present, are immediately looked up and
--   converted into 'Entity' and 'TRobot' values.  If they are not
--   found, a parse error results.
instance FromJSONE (EntityMap, RobotMap) (AugmentedCell Entity) where
  parseJSONE x = case x of
    Object v -> objParse v
    z -> AugmentedCell Nothing <$> parseJSONE z
   where
    objParse v =
      AugmentedCell
        <$> liftE (v .:? "waypoint")
        <*> v
          ..: "cell"

------------------------------------------------------------
-- World editor
------------------------------------------------------------

-- | Stateless cells used for the World Editor.
-- These cells contain the bare minimum display information
-- for rendering.
type CellPaintDisplay = PCell EntityFacade

-- Note: This instance is used only for the purpose of 'WorldPalette'
instance ToJSON CellPaintDisplay where
  toJSON = mkPCellJson $ \case
    ENothing -> Nothing
    EErase -> Just $ EntityFacade "erase" mempty
    EJust e -> Just e
