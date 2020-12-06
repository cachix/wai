{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}

module Network.Wai.Handler.Warp.HTTP1 (
    http1
  ) where

import "iproute" Data.IP (toHostAddress, toHostAddress6)
import qualified Control.Concurrent as Conc (yield)
import Control.Exception as E
import qualified Data.ByteString as S
import Data.Char (chr)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Network.Socket (SockAddr(SockAddrInet, SockAddrInet6))
import Network.Wai
import Network.Wai.Internal (ResponseReceived (ResponseReceived))
import qualified System.TimeManager as T

import Network.Wai.Handler.Warp.Header
import Network.Wai.Handler.Warp.Imports hiding (readInt)
import Network.Wai.Handler.Warp.ReadInt
import Network.Wai.Handler.Warp.Request
import Network.Wai.Handler.Warp.Response
import Network.Wai.Handler.Warp.Settings
import Network.Wai.Handler.Warp.Types

http1 :: Settings -> InternalInfo -> Connection -> Transport -> (Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived) -> SockAddr -> T.Handle -> ByteString -> IO ()
http1 settings ii conn transport app origAddr th bs = do
    istatus <- newIORef True
    src <- mkSource (wrappedRecv conn th istatus (settingsSlowlorisSize settings))
    leftoverSource src bs
    addr <- getProxyProtocolAddr src
    loop True addr istatus src `E.catch` \e ->
          case () of
            ()
             -- See comment below referencing
             -- https://github.com/yesodweb/wai/issues/618
             | Just NoKeepAliveRequest <- fromException e -> return ()
             -- No valid request
             | Just (BadFirstLine _)   <- fromException e -> return ()
             | otherwise -> do
               _ <- sendErrorResponse (dummyreq addr) istatus e
               throwIO e
  where
    loop firstRequest addr istatus src = do
        (req, mremainingRef, idxhdr, nextBodyFlush) <- recvRequest firstRequest settings conn ii th addr src transport
        keepAlive <- processRequest istatus src req mremainingRef idxhdr nextBodyFlush
            `E.catch` \e -> do
                settingsOnException settings (Just req) e
                -- Don't throw the error again to prevent calling settingsOnException twice.
                return False

        -- When doing a keep-alive connection, the other side may just
        -- close the connection. We don't want to treat that as an
        -- exceptional situation, so we pass in False to http1 (which
        -- in turn passes in False to recvRequest), indicating that
        -- this is not the first request. If, when trying to read the
        -- request headers, no data is available, recvRequest will
        -- throw a NoKeepAliveRequest exception, which we catch here
        -- and ignore. See: https://github.com/yesodweb/wai/issues/618

        when keepAlive $ loop False addr istatus src

    processRequest istatus src req mremainingRef idxhdr nextBodyFlush = do
        -- Let the application run for as long as it wants
        T.pause th

        -- In the event that some scarce resource was acquired during
        -- creating the request, we need to make sure that we don't get
        -- an async exception before calling the ResponseSource.
        keepAliveRef <- newIORef $ error "keepAliveRef not filled"
        r <- E.try $ app req $ \res -> do
            T.resume th
            -- FIXME consider forcing evaluation of the res here to
            -- send more meaningful error messages to the user.
            -- However, it may affect performance.
            writeIORef istatus False
            keepAlive <- sendResponse settings conn ii th req idxhdr (readSource src) res
            writeIORef keepAliveRef keepAlive
            return ResponseReceived
        case r of
            Right ResponseReceived -> return ()
            Left e@(SomeException _)
              | Just (ExceptionInsideResponseBody e') <- fromException e -> throwIO e'
              | otherwise -> do
                    keepAlive <- sendErrorResponse req istatus e
                    settingsOnException settings (Just req) e
                    writeIORef keepAliveRef keepAlive

        keepAlive <- readIORef keepAliveRef

        -- We just send a Response and it takes a time to
        -- receive a Request again. If we immediately call recv,
        -- it is likely to fail and cause the IO manager to do some work.
        -- It is very costly, so we yield to another Haskell
        -- thread hoping that the next Request will arrive
        -- when this Haskell thread will be re-scheduled.
        -- This improves performance at least when
        -- the number of cores is small.
        Conc.yield

        if keepAlive
          then
            -- If there is an unknown or large amount of data to still be read
            -- from the request body, simple drop this connection instead of
            -- reading it all in to satisfy a keep-alive request.
            case settingsMaximumBodyFlush settings of
                Nothing -> do
                    flushEntireBody nextBodyFlush
                    T.resume th
                    return True
                Just maxToRead -> do
                    let tryKeepAlive = do
                            -- flush the rest of the request body
                            isComplete <- flushBody nextBodyFlush maxToRead
                            if isComplete then do
                                T.resume th
                                return True
                              else
                                return False
                    case mremainingRef of
                        Just ref -> do
                            remaining <- readIORef ref
                            if remaining <= maxToRead then
                                tryKeepAlive
                              else
                                return False
                        Nothing -> tryKeepAlive
          else
            return False

    shouldSendErrorResponse se
        | Just ConnectionClosedByPeer <- fromException se = False
        | otherwise                                       = True

    sendErrorResponse req istatus e = do
        status <- readIORef istatus
        if shouldSendErrorResponse e && status
            then do
                sendResponse settings conn ii th req defaultIndexRequestHeader (return S.empty) (errorResponse e)
            else return False

    getProxyProtocolAddr src =
        case settingsProxyProtocol settings of
            ProxyProtocolNone ->
                return origAddr
            ProxyProtocolRequired -> do
                seg <- readSource src
                parseProxyProtocolHeader src seg
            ProxyProtocolOptional -> do
                seg <- readSource src
                if S.isPrefixOf "PROXY " seg
                    then parseProxyProtocolHeader src seg
                    else do leftoverSource src seg
                            return origAddr

    parseProxyProtocolHeader src seg = do
        let (header,seg') = S.break (== 0x0d) seg -- 0x0d == CR
            maybeAddr = case S.split 0x20 header of -- 0x20 == space
                ["PROXY","TCP4",clientAddr,_,clientPort,_] ->
                    case [x | (x, t) <- reads (decodeAscii clientAddr), null t] of
                        [a] -> Just (SockAddrInet (readInt clientPort)
                                                       (toHostAddress a))
                        _ -> Nothing
                ["PROXY","TCP6",clientAddr,_,clientPort,_] ->
                    case [x | (x, t) <- reads (decodeAscii clientAddr), null t] of
                        [a] -> Just (SockAddrInet6 (readInt clientPort)
                                                        0
                                                        (toHostAddress6 a)
                                                        0)
                        _ -> Nothing
                ("PROXY":"UNKNOWN":_) ->
                    Just origAddr
                _ ->
                    Nothing
        case maybeAddr of
            Nothing -> throwIO (BadProxyHeader (decodeAscii header))
            Just a -> do leftoverSource src (S.drop 2 seg') -- drop CRLF
                         return a

    decodeAscii = map (chr . fromEnum) . S.unpack
    errorResponse e = settingsOnExceptionResponse settings e
    dummyreq addr = defaultRequest { remoteHost = addr }

wrappedRecv :: Connection -> T.Handle -> IORef Bool -> Int -> IO ByteString
wrappedRecv Connection { connRecv = recv } th istatus slowlorisSize = do
    bs <- recv
    unless (S.null bs) $ do
        writeIORef istatus True
        when (S.length bs >= slowlorisSize) $ T.tickle th
    return bs
flushEntireBody :: IO ByteString -> IO ()
flushEntireBody src =
    loop
  where
    loop = do
        bs <- src
        unless (S.null bs) loop

flushBody :: IO ByteString -- ^ get next chunk
          -> Int -- ^ maximum to flush
          -> IO Bool -- ^ True == flushed the entire body, False == we didn't
flushBody src =
    loop
  where
    loop toRead = do
        bs <- src
        let toRead' = toRead - S.length bs
        case () of
            ()
                | S.null bs -> return True
                | toRead' >= 0 -> loop toRead'
                | otherwise -> return False
