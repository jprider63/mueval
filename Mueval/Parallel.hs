module Mueval.Parallel where

import Control.Concurrent (forkIO, killThread, myThreadId, threadDelay, throwTo, ThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, MVar)
import Control.Exception.Extensible as E (ErrorCall(..),SomeException,catch)
import Control.Monad (void)
import System.IO (hSetBuffering, stdout, BufferMode(NoBuffering))
import System.Posix.Signals (sigXCPU, installHandler, Handler(CatchOnce))

import Mueval.Interpreter
import Mueval.ArgsParse

-- | Fork off a thread which will sleep and then kill off the specified thread.
watchDog :: Int -> ThreadId -> ThreadId -> IO ThreadId
watchDog tout mid cid = do
    forkIO $ do
                threadDelay (tout * 700000)
                -- Time's up. It's a good day to die.
                timeoutHandler mid cid
    -- return () -- Never reached. Either we error out here
    --           -- or the evaluation thread finishes.

data TimeoutHandler = TimeoutHandler {
      timeoutHandlerDone :: (MVar Bool)
    , runTimeoutHandler :: IO ()
    }

timeoutHandler :: ThreadId -> ThreadId -> IO TimeoutHandler
timeoutHandler mid cids = do
    doneMVar <- newMVar False
    return $ TimeoutHandler doneMVar $ do
        -- Say we're done.
        done <- swapMVar doneMVar True

        -- Kill child if we're not done.
        unless done $ do
            throwTo mid (ErrorCall "Time limit exceeded") -- Notify main thread.
            mapM_ killThread cids -- Die now, srsly.
            -- error "Time expired"

-- | A basic blocking operation.
block :: (t -> MVar a -> IO t1) -> t -> IO a
block f opts = do  mvar <- newEmptyMVar
                   _ <- f opts mvar
                   takeMVar mvar -- block until ErrorCall, or forkedMain succeeds

-- | Using MVars, block on 'forkedMain' until it finishes.
forkedMain :: Options -> IO ()
forkedMain opts = void (block forkedMain' opts)


-- | Set a 'watchDog' on this thread, and then continue on with whatever.
forkedMain' :: Options -> MVar String -> IO ThreadId
forkedMain' opts mvar = forked' (interpreterSession (checkImport opts)
                            >> return "Done.") (timeLimit opts) mvar
          where checkImport x = if noImports x then x{modules=Nothing} else x

-- | Set a 'watchDog' on this thread, fork the IO function, and block until it completes.
forked :: IO a -> Int -> IO a
forked f timeLimit = block (forked' f) timeLimit

-- | Set a 'watchDog' on this thread, and then fork/run the IO function.
forked' :: IO a -> Int -> MVar a -> IO ThreadId
forked' f timeLimit mvar = do mainId <- myThreadId
                              watchDog timeLimit mainId
                              hSetBuffering stdout NoBuffering

                              -- Our modules and expression are set up. Let's do stuff.
                              childId <- forkIO $ (do
                                    cid <- myThreadId
                                    _ <- installHandler sigXCPU
                                          (CatchOnce $ timeoutHandler mainId cid) Nothing
                              
                                    f >>= putMVar mvar
                                ) `E.catch` \e -> throwTo mainId (e::SomeException)
                                                                -- bounce exceptions to the main thread,
                                                                -- so they are reliably printed out
                              
                              childId
