module Game.Robo.Core.Bot where

import Lens.Family2
import Lens.Family2.State

import Control.Concurrent

import Control.Applicative
import Data.Traversable
import Control.Monad
import Control.Monad.Writer
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Random
import System.Random

import Data.Array.MArray
import Data.Array.IO

import Data.Vector.Class
import Data.List
import Data.Ord
import Data.Maybe

import Game.Robo.Core
import Game.Robo.Maths
import Game.Robo.Draw.DrawWorld

initialBotState ::  Scalar -> BotID -> Vec -> BotState
initialBotState mass bid pos =
  BotState { _botID        = bid
           , _botThrust    = 0
           , _botAngThrust = 0
           , _botPos       = pos
           , _botHeading   = 0
           , _botSpeed     = 0
           , _botAngVel    = 0

           , _botGun   = GunState   { _gunHeading = 0
                                    , _gunFiring  = 0
                                    , _gunAngVel  = 0 }

           , _botRadar = RadarState { _radHeading = 0
                                    , _radAngVel  = 0 }

           , _botMass      = mass
           }

-- | Calculate the robot's new position after some time has passed.
-- Approximates many integrals.
stepBotMotion :: Double -> Bot ()
stepBotMotion passed = do
  driveFric <- asks (view ruleDriveFriction)
  turnFric  <- asks (view ruleTurnFriction)

  angThrust <- use botAngThrust
  angVel    <- use botAngVel
  heading   <- use botHeading

  let angVel'  = turnFric * (angVel + angThrust * passed)
      heading' = angNormAbsolute $ heading + angVel' * passed
      dir      = vecFromAngle heading'

  thrust    <- use botThrust
  mass      <- use botMass
  speed     <- use botSpeed
  pos       <- use botPos
  let acc    = thrust / mass
      speed' = driveFric * (speed + acc * passed)
      pos'   = pos + dir |* (speed' * passed)

  botAngVel  .= angVel'
  botHeading .= heading'
  botSpeed   .= speed'
  botPos     .= pos'

-- | Creates a bullet moving away from the end of the robot's gun,
-- and sets the firepower back to 0.
fireBullet :: Bot Bullet
fireBullet = do
  firing <- use (botGun.gunFiring)
  pos    <- use botPos
  bid    <- use botID
  speed  <- asks (view ruleBulletSpeed)
  gunSize<- asks (view ruleGunSize)
  botAng <- use botHeading
  gunAng <- use (botGun.gunHeading)
  let ang = botAng + gunAng
      vel = rotateVec ang (vec speed 0)
      offset = rotateVec ang (vec (gunSize^.vX) 0)
      bul = Bullet { _bulVel = vel
                   , _bulPos = pos + offset
                   , _bulPower = firing
                   , _bulOwner = bid }

  botGun.gunFiring .= 0

  return bul

-- | Update the robot's gun, returning a list of newly fired bullets.
stepBotGun :: Double -> Bool -> Bot [Bullet]
stepBotGun passed doTick = do
  vel <- use (botGun.gunAngVel)
  botGun.gunHeading += vel * passed
  firing <- use (botGun.gunFiring)
  bullets <- if doTick && firing > 0
                then (:[]) <$> fireBullet
                else return []

  return bullets

-- | Update the motion of the robot's radar.
stepBotRadar :: Double -> Bot ()
stepBotRadar passed = do
  vel <- use (botRadar.radAngVel)
  botRadar.radHeading += vel * passed

-- | Update the robot after some time has passed.
stepBot :: Double -> Bool -> Bot [Bullet]
stepBot passed doTick = do
  stepBotMotion passed
  bullets <- stepBotGun passed doTick
  stepBotRadar passed
  return bullets

-- | Makes a Rect specifying the robot's bounds.
botRect :: Bot Rect
botRect = do
  sz  <- asks (view ruleBotSize)
  ang <- use botHeading
  pos <- use botPos
  return $ rect pos sz ang

-- | Scans for other robots within this robot's field of view.
tryScan :: [BotState] -> Bot (Maybe ScanData)
tryScan bots = do
  pos   <- use botPos
  bid   <- use botID
  fov   <- asks (view ruleRadFOV)
  range <- asks (view ruleRadRange)
  rh    <- use (botRadar.radHeading)
  bh    <- use botHeading
  let facingAngle = rh + bh
      minAngle = facingAngle - fov / 2
      maxAngle = facingAngle + fov / 2
      -- get all bots within the scan segment
      targets = filter (inSegmentCentre minAngle maxAngle range pos . view botPos) bots
      -- make sure the current bot isn't included
      notUs   = filter ((/= bid) . view botID) targets
      -- sort by distance
      sorted  = sortBy (comparing (vecMag . subtract pos . view botPos)) notUs

  -- return the closet bot, if it exists
  return $ case sorted of
    bot : _ ->
      let thatPos = bot^.botPos
          dist = vecMag (pos - thatPos)
          ang  = pos `angleTo` thatPos
      in  Just $ ScanData dist ang
    _       -> Nothing

-- | Tests if a bullet has hit the robot, and returns Nothing if so.
testBulletHit :: Bullet -> Bot (Maybe Bullet)
testBulletHit bul = do
  bid <- use botID
  box <- botRect
  let bpos = bul^.bulPos
      owner = bul^.bulOwner
  return $ if owner /= bid && withinRect bpos box
              then Nothing
              else Just bul

-- | Print a log from a robot with the given name to the console.
writeLog :: String -> [String] -> IO ()
writeLog name = putStr . unlines . map ((name ++ ": ") ++)

-- | Run a robot. This never terminates and is designed to be called in its own thread.
-- Communicates with the World thread via channels.
runBot :: BattleRules -> BotSpec -> BotState -> BotID -> UpdateChan -> ResponseChan -> IO ()
runBot rules spec state1 bid updateChan responseChan =
  case spec of
    (BotSpec name initialState onInit' onTick' onScan') ->
      do -- run the robot's initialisation method
         gen <- newStdGen
         let ((_, userState1), state1', log1) =
               evalBot (runRobo onInit' initialState) gen rules state1
         writeLog name log1
         -- send the initialised BotState to the main thread
         writeChan responseChan (bid, state1', [])

         -- start the main loop
         loop userState1 where
           loop userState = do
             -- wait until the main thread tells us to advance
             (botState, worldState, passed, doTick) <- readChan updateChan

             -- update the robot state
             gen <- newStdGen
             let bot = do
                   bullets <- stepBot passed doTick
                   mscan   <- tryScan (worldState^.wldBots)
                   let roboActions = do
                         when doTick onTick'
                         case mscan of
                           Just scan -> onScan' scan
                           Nothing   -> return ()
                   (_, userState') <- runRobo roboActions userState
                   return (bullets, userState')

                 ((bullets, userState'), botState', log) = evalBot bot gen rules botState

             -- print out the log to the console for now
             writeLog name log

             -- pass the robot state back to the main thread
             writeChan responseChan (bid, botState', bullets)

             -- loop forever (until the thread is terminated)
             loop userState'