{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE CPP #-}

module Network.Wai.Handler.Warp.Recv (
    receive
  , receiveBuf
  ) where

#if __GLASGOW_HASKELL__ < 709
import Control.Applicative ((<$>))
#endif
import Data.ByteString (ByteString)
import Data.Word (Word8)
import Foreign.C.Error (eAGAIN, getErrno, throwErrno)
import Foreign.C.Types
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import GHC.Conc (threadWaitRead)
import Network.Socket (Socket, fdSocket)
import Network.Wai.Handler.Warp.Types
import Network.Wai.Handler.Warp.Buffer
import System.Posix.Types (Fd(..))

#ifdef mingw32_HOST_OS
import GHC.IO.FD (FD(..), readRawBufferPtr)
import Network.Wai.Handler.Warp.Windows
#endif

----------------------------------------------------------------

receive :: Socket -> BufferPool -> IO ByteString
receive sock pool = withBufferPool pool $ \ (ptr, size) -> do
    let sock' = fdSocket sock
        size' = fromIntegral size
    fromIntegral <$> receiveloop sock' ptr size'

receiveBuf :: Socket -> Buffer -> BufSize -> IO ()
receiveBuf sock buf0 siz0 = loop buf0 siz0
  where
    loop _   0   = return ()
    loop buf siz = do
        n <- fromIntegral <$> receiveloop fd buf (fromIntegral siz)
        loop (buf `plusPtr` n) (siz - n)
    fd = fdSocket sock

receiveloop :: CInt -> Ptr Word8 -> CSize -> IO CInt
receiveloop sock ptr size = do
#ifdef mingw32_HOST_OS
    bytes <- windowsThreadBlockHack $ fmap fromIntegral $ readRawBufferPtr "recv" (FD sock 1) (castPtr ptr) 0 size
#else
    bytes <- c_recv sock (castPtr ptr) size 0
#endif
    if bytes == -1 then do
        errno <- getErrno
        if errno == eAGAIN then do
            threadWaitRead (Fd sock)
            receiveloop sock ptr size
          else
            throwErrno "receiveloop"
       else
        return bytes

-- fixme: the type of the return value
foreign import ccall unsafe "recv"
    c_recv :: CInt -> Ptr CChar -> CSize -> CInt -> IO CInt
