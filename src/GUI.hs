{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE DeriveFoldable            #-}
{-# LANGUAGE DeriveFunctor             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE KindSignatures            #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeApplications          #-}
{-# LANGUAGE TypeOperators             #-}
{-# LANGUAGE UndecidableInstances      #-}
{-# LANGUAGE UndecidableSuperClasses   #-}

module GUI where

import           Control.Algebra
import           Control.Carrier.Lift
import           Control.Carrier.Reader
import           Control.Carrier.State.Strict
-- import Optics

import           Control.Concurrent
import           Control.Effect.Optics (use, (%=), (.=))
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Dynamic
import           Data.Foldable (forM_)
import           Data.Kind
import           Data.Maybe
import           Data.Text (Text, pack)
import           Data.Typeable
import           Data.Word (Word8)
import           Foreign.Ptr
import           Foreign.StablePtr
import           GHC.Real (Integral)
import           Graph
import           MyLib
import           Optics (_1, _2, ix, (%), (^.))
import           SDL
import           SDL.Font as SF
import           SDL.Framerate
import           SDL.Primitive
import           System.Process
import           Type
import           Widget

data Body = Body
  { _workPath :: FilePath
  }

bodyWidget' :: FilePath -> [BasePositon] -> Widget Body
bodyWidget' fp i =
  Widget
    { _width = 100,
      _heigh = 100,
      _model = Body fp,
      _backgroundColor = 255,
      _frontColor = 90,
      _visible = True,
      _path = [],
      _children = maketgwWidget' i
      -- [ (200, SomeWidget (tgeWidget [0])),
      --   (300, SomeWidget (tgeWidget [1]))
      -- ]
    }

instance WidgetRender Body where
  renderSelf bp w@Widget {..} = do
    renderer <- asks _renderer
    clear renderer

inRectangle :: (Ord a, Num a, Integral b) => Point V2 a -> Rectangle b -> Bool
inRectangle (P v0@(V2 x0 y0)) (Rectangle (P vs) size) =
  let V2 x1 y1 = fmap fromIntegral vs
      V2 x2 y2 = fmap fromIntegral (vs + size)
   in x0 > x1 && x0 < x2 && y0 > y1 && y0 < y2

-- v0 > fmap fromIntegral vs && v0 < fmap fromIntegral (vs + size)

instance WidgetHandler Body where
  handler es a@Widget {..} = mapM_ handler1 es >> return ()
    where
      handler1 e = do
        case eventPayload e of
          (MouseButtonEvent (MouseButtonEventData _ Pressed _ ButtonRight _ pos)) -> do
            ls <- use (bodyWidget % children')
            let vs = map (\(bp, sw) -> (Rectangle bp (V2 (sw ^. width') (sw ^. height')), sw ^. path')) ls
                posIn = listToMaybe $ map snd $ filter (inRectangle pos . Prelude.fst) vs
            case posIn of
              Just [i] -> do
                liftIO $ void $ forkIO $ void $ system $ "gedit " ++ _workPath _model ++ "/s" ++ show i ++ ".txt"
                return ()
              _ -> return ()
          (MouseMotionEvent (MouseMotionEventData _ _ [ButtonLeft] pos relPos)) -> do
            ls <- use (bodyWidget % children')
            let vs = map (\(bp, sw) -> (Rectangle bp (V2 (sw ^. width') (sw ^. height')), sw ^. path')) ls
                posIn = listToMaybe $ map snd $ filter (inRectangle pos . Prelude.fst) vs
            case posIn of
              Just [i] -> do
                bodyWidget % children' % ix i % _1 %= (\(P v) -> P $ v + fmap fromIntegral relPos)
              _ -> return ()
          (KeyboardEvent (KeyboardEventData _ Pressed _ (Keysym _ KeycodeA _))) -> do
            allPos <- use $ bodyWidget % children'
            liftIO $ writeFile (_workPath _model ++ "/position.txt") (show $ fmap fst allPos)
          UserEvent _ -> do
            ge <- asks _getUserEvent
            ue <- liftIO $ ge e
            case ue >>= fromDynamic @TraceGraphEval of
              Nothing -> return ()
              Just d@GR {..} -> do
                bodyWidget % children' % ix nodeId % _2 .= SomeWidget (tgeWidget' d [nodeId])
          -- liftIO $ print d
          _ -> return ()

makeUIState :: FilePath -> [BasePositon] -> UIState
makeUIState fp i =
  UIState
    { _bodyWidget = SomeWidget $ bodyWidget' fp i,
      _focus = []
    }

newtype Model = Model Int deriving (Show)

mkp :: Int -> Int -> BasePositon
mkp x y = P $ V2 x y

modelWidget :: [Int] -> Widget Model
modelWidget path =
  Widget
    { _width = 100,
      _heigh = 100,
      _model = Model 1,
      _backgroundColor = 30,
      _frontColor = V4 0 0 0 255,
      _visible = True,
      _path = path,
      _children =
        [ (mkp 15 25, SomeWidget $ textWidget [1, 2]),
          (mkp 15 50, SomeWidget $ textWidget [1, 2])
        ]
    }

instance WidgetRender Model where
  renderSelf bp w@Widget {..} = do
    renderer <- asks _renderer
    font <- asks _font
    liftIO $ do
      renderFont font renderer (pack $ show _model ++ show _path) (fmap fromIntegral bp) _frontColor

instance WidgetHandler Model where
  handler e a = do
    return ()

textWidget :: [Int] -> Widget Text
textWidget path =
  Widget
    { _width = 80,
      _heigh = 30,
      _model = "welcome ",
      _backgroundColor = 30,
      _frontColor = V4 255 0 0 255,
      _visible = True,
      _path = path,
      _children = []
    }

instance WidgetRender Text where
  renderSelf bp w@Widget {..} = do
    renderer <- asks _renderer
    font <- asks _font
    liftIO $ do
      renderFont font renderer _model (fmap fromIntegral bp) _frontColor

instance WidgetHandler Text where
  handler e a = return ()

makeBP :: Int -> [BasePositon]
makeBP i = [P (V2 (i * 100) 0) | i <- [0 .. (i -1)]]

maketgwWidget' :: [BasePositon] -> [(BasePositon, SomeWidget)]
maketgwWidget' p = zip p (map (SomeWidget . tgeWidget . (: [])) [0 ..])

tgeWidget :: [Int] -> Widget TraceGraphEval
tgeWidget path =
  Widget
    { _width = 100,
      _heigh = 30,
      _model = defaultGR,
      _backgroundColor = 30,
      _frontColor = V4 255 0 0 255,
      _visible = True,
      _path = path,
      _children = []
    }

red :: V4 Word8
red = V4 255 0 0 255

green :: V4 Word8
green = V4 0 255 0 255

blue :: V4 Word8
blue = V4 0 0 255 255

black :: V4 Word8
black = 0

tgeWidget' :: TraceGraphEval -> [Int] -> Widget TraceGraphEval
tgeWidget' v path =
  Widget
    { _width = 100,
      _heigh = 30,
      _model = v,
      _backgroundColor = 30,
      _frontColor = V4 255 0 0 255,
      _visible = True,
      _path = path,
      _children = []
    }

showLit :: Lit -> String
showLit (LitStr s) = s
showLit (LitNum d) = show d
showLit LitNull    = "null"
showLit _          = "unspport"

showExpr :: Expr -> String
showExpr (Elit l)  = showLit l
showExpr Skip      = "skip"
showExpr (Fun _ _) = "function"
showExpr _         = "unspport"

instance WidgetRender TraceGraphEval where
  renderSelf bp@(P (V2 x y)) w@Widget {..} = do
    renderer <- asks _renderer
    font <- asks _font
    let GR {..} = _model
    liftIO $ do
      renderFont
        font
        renderer
        (pack $ "node s" ++ show nodeId)
        (fmap fromIntegral bp)
        (if isSkip result then green else _frontColor)
      let bpResult = P (V2 x (y + 30))

      renderFont font renderer (pack $ "output: " <> showExpr result) (fmap fromIntegral bpResult) MyLib.blue
      let P (V2 x1 y1) = P (V2 (fromIntegral x) (fromIntegral y + 60))

      forM_ (zip [0 ..] vars) $ \(idx, (name, e)) -> do
        renderFont font renderer (pack $ show name ++ ": " ++ showExpr e) (P (V2 x1 (y1 + idx * 30))) black

instance WidgetHandler TraceGraphEval where
  handler e a = do
    return ()

defaultGR =
  GR
    { nodeId = 1,
      vars =
        [ ("a", Elit (LitNum 30)),
          ("b", Elit (LitNum 30))
        ],
      result = Elit (LitNum 10)
    }

initGUI :: IO (Renderer, Font, Manager, TraceGraphEval -> IO EventPushResult, Event -> IO (Maybe Dynamic))
initGUI = do
  initializeAll
  SF.initialize
  let toTimerEvent (RegisteredEventData _ 0 ptr nullPtr) _ = do
        let sp = castPtrToStablePtr ptr
        a <- deRefStablePtr sp
        freeStablePtr sp
        return . Just $ a
      toTimerEvent _ _ = error "never happened"

      fromTimerEvent b = do
        sp <- newStablePtr b
        let ptr = castStablePtrToPtr sp
        return (RegisteredEventData Nothing 0 ptr nullPtr)
  registerEvent <- registerEvent toTimerEvent fromTimerEvent
  (pe, ge) <- case registerEvent of
    Nothing -> error "regieter event error"
    Just (RegisteredEventType pe ge) -> do
      return (pe, ge)
  window <-
    createWindow
      "resize"
      WindowConfig
        { windowBorder = True,
          windowHighDPI = False,
          windowInputGrabbed = False,
          windowMode = Windowed,
          windowGraphicsContext = NoGraphicsContext,
          windowPosition = Wherever,
          windowResizable = True,
          windowInitialSize = V2 800 600,
          windowVisible = True
        }
  renderer <- createRenderer window (-1) defaultRenderer
  addEventWatch $ \ev ->
    case eventPayload ev of
      WindowSizeChangedEvent sizeChangeData ->
        putStrLn $ "eventWatch windowSizeChanged: " ++ show sizeChangeData
      _ -> return ()
  fm <- SDL.Framerate.manager
  SDL.Framerate.set fm 30
  font <- load "/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf" 20
  return (renderer, font, fm, pe, fmap (fmap toDyn) . ge)

appLoop1 :: forall sig m.
            (UI sig m,
             MonadIO m)
         => m ()
appLoop1 = go
  where
    go = do
      e <- liftIO pollEvents
      use bodyWidget >>= handlerSomeWidget e

      -- TODO: dispatch event to focus widget

      use bodyWidget >>= renderSomeWidget 0

      renderer <- asks _renderer
      present renderer
      man <- asks _manager
      delay_ man
      go

-- main :: IO ()
-- main = do
--   (r, f, m, pe, ge) <- initGUI
--   runReader (UIEnv r f m ge) $ runState (makeUIState "" (makeBP 5)) appLoop1
--   return ()
