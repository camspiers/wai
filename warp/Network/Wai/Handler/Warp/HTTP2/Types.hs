{-# LANGUAGE OverloadedStrings, CPP #-}

module Network.Wai.Handler.Warp.HTTP2.Types where

#if __GLASGOW_HASKELL__ < 709
import Control.Applicative ((<$>),(<*>))
#endif
import Control.Concurrent
import Control.Concurrent.STM
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as M
import qualified Network.HTTP.Types as H
import Network.Wai (Request, Response)
import Network.Wai.Handler.Warp.Buffer
import Network.Wai.Handler.Warp.IORef
import Network.Wai.Handler.Warp.Types

import Network.HTTP2
import Network.HTTP2.Priority
import Network.HPACK

----------------------------------------------------------------

http2ver :: H.HttpVersion
http2ver = H.HttpVersion 2 0

isHTTP2 :: Transport -> Bool
isHTTP2 TCP = False
isHTTP2 tls = useHTTP2
  where
    useHTTP2 = case tlsNegotiatedProtocol tls of
        Nothing    -> False
        Just proto -> "h2-" `BS.isPrefixOf` proto

----------------------------------------------------------------

data Next = Next Int (Maybe (WindowSize -> IO Next))

data Input = Input Stream Request Priority
data Output = OFinish
            | OGoaway ByteString
            | OFrame  ByteString
            | OResponse Stream Response
            | ONext Stream (WindowSize -> IO Next)

type StreamTable = IntMap Stream

data Context = Context {
    http2settings      :: IORef Settings
  , streamTable        :: IORef StreamTable
  , concurrency        :: IORef Int
  , continued          :: IORef (Maybe StreamId)
  , currentStreamId    :: IORef StreamId
  , inputQ             :: TQueue Input
  , outputQ            :: PriorityTree Output
  , encodeDynamicTable :: IORef DynamicTable
  , decodeDynamicTable :: IORef DynamicTable
  , wait               :: MVar ()
  , connectionWindow   :: TVar WindowSize
  }

----------------------------------------------------------------

newContext :: IO Context
newContext = Context <$> newIORef defaultSettings
                     <*> newIORef M.empty
                     <*> newIORef 0
                     <*> newIORef Nothing
                     <*> newIORef 0
                     <*> newTQueueIO
                     <*> newPriorityTree
                     <*> (newDynamicTableForEncoding 4096 >>= newIORef)
                     <*> (newDynamicTableForDecoding 4096 >>= newIORef)
                     <*> newEmptyMVar
                     <*> newTVarIO defaultInitialWindowSize

----------------------------------------------------------------

data ClosedCode = Finished | Killed | Reset ErrorCodeId deriving Show

data StreamState =
    Idle
  | Continued [HeaderBlockFragment] Bool Priority
  | NoBody HeaderList Priority
  | HasBody HeaderList Priority
  | Body (TQueue ByteString)
  | HalfClosed
  | Closed ClosedCode

instance Show StreamState where
    show Idle              = "Idle"
    show (Continued _ _ _) = "Continued"
    show (NoBody  _ _)     = "NoBody"
    show (HasBody _ _)     = "HasBody"
    show (Body    _)       = "Body"
    show HalfClosed        = "HalfClosed"
    show (Closed e)        = "Closed: " ++ show e

----------------------------------------------------------------

data Stream = Stream {
    streamNumber        :: StreamId
  , streamState         :: IORef StreamState
  -- Next two fields are for error checking.
  , streamContentLength :: IORef (Maybe Int)
  , streamBodyLength    :: IORef Int
  , streamWindow        :: TVar WindowSize
  }

newStream :: StreamId -> WindowSize -> IO Stream
newStream sid win = Stream sid <$> newIORef Idle
                               <*> newIORef Nothing
                               <*> newIORef 0
                               <*> newTVarIO win

----------------------------------------------------------------

data Source2 = Source2 !(IORef ByteString) !(IO ByteString) !RecvBuf

mkSource2 :: ByteString -> IO ByteString -> RecvBuf -> IO Source2
mkSource2 initial recv recvBuf = do
    ref <- newIORef initial
    return $! Source2 ref recv recvBuf

readSource2 :: Source2 -> Int -> IO ByteString
readSource2 (Source2 ref recv recvBuf) size = do
    cached <- readIORef ref
    (bs, leftover) <- spell cached size recv recvBuf
    writeIORef ref leftover
    return bs

leftoverSource2 :: Source2 -> ByteString -> IO ()
leftoverSource2 (Source2 ref _ _) bs = writeIORef ref bs
