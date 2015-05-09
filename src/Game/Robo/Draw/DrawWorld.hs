module Game.Robo.Draw.DrawWorld where

import Graphics.UI.SDL as SDL
import Graphics.UI.SDL.Primitives
import Graphics.UI.SDL.Rotozoomer as GFX

import Lens.Family2
import Lens.Family2.State
import Lens.Family2.Stock

import Control.Monad
import Control.Monad.State
import Control.Monad.Reader
import Data.Traversable
import Control.Applicative ((<$>))

import Game.Robo.Core.Types
import Game.Robo.Draw.DrawBot
import Game.Robo.Maths

drawBullet :: Surface -> Bullet -> DrawWorld
drawBullet surface bul = do
  let pos = bul^.bulPos
      pow = bul^.bulPower

      (cx, cy) = (round (pos^.vX), round (pos^.vY))
      size = round (sqrt pow * 2.5)

  liftIO . void $ circle surface cx cy size (Pixel 0xFF8888FF)

drawWorld :: Surface -> DrawWorld
drawWorld surface = do
    liftIO . void $ fillRect surface Nothing (Pixel 0xFF100808)

    bots <- use wldBots
    mapM_ (drawBot surface) bots

    buls <- use wldBullets
    mapM_ (drawBullet surface) buls