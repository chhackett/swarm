-- |
-- SPDX-License-Identifier: BSD-3-Clause
module Swarm.Game.Step.Util.Inspect where

import Control.Carrier.State.Lazy
import Control.Effect.Lens
import Control.Lens hiding (from, use, (%=), (<.>))
import Data.IntMap qualified as IM
import Data.List (find)
import Data.Text (Text)
import Swarm.Game.Location
import Swarm.Game.Robot
import Swarm.Game.State
import Swarm.Game.Universe
import Swarm.Language.Direction
import Swarm.Util (listEnums)

-- * World queries

getNeighborLocs :: Cosmic Location -> [Cosmic Location]
getNeighborLocs loc = map (offsetBy loc . flip applyTurn north . DRelative . DPlanar) listEnums

-- | Get the robot with a given ID.
robotWithID :: (Has (State GameState) sig m) => RID -> m (Maybe Robot)
robotWithID rid = use (robotMap . at rid)

-- | Get the robot with a given name.
robotWithName :: (Has (State GameState) sig m) => Text -> m (Maybe Robot)
robotWithName rname = use (robotMap . to IM.elems . to (find $ \r -> r ^. robotName == rname))
