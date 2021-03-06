-- This file is part of gearman-haskell.
--
-- Copyright 2014 Anchor Systems Pty Ltd and others.
--
-- The code in this file, and the program it is a part of, is made
-- available to you by its authors as open source software: you can
-- redistribute it and/or modify it under the terms of the BSD license.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module System.Gearman.Connection(
    Connection(..),
    connect,
    echo,
    runGearman,
    runGearmanAsync,
    GearmanAsync(..),
    Gearman,
    sendPacket,
    sendPacketIO,
    recvPacket,
    recvBytes

) where

import Prelude
import Control.Applicative
import Control.Monad.Trans
import Control.Monad.Reader
import Control.Concurrent.Async
import Control.Exception
import Data.Either
import qualified Network.Socket as N
import Network.Socket.ByteString
import qualified Data.ByteString.Char8 as S
import qualified Data.ByteString.Lazy as L

import System.Gearman.Error
import System.Gearman.Protocol

data Connection = Connection {
    connHost :: String,
    connPort :: String,
    sock :: N.Socket
}

newtype Gearman a = Gearman (ReaderT Connection IO a)
    deriving (Functor, Applicative, Monad, MonadIO, MonadReader Connection)

newtype GearmanAsync a = GearmanAsync (ReaderT Connection IO a)
    deriving (Functor, Applicative, Monad, MonadIO, MonadReader Connection)

runGearmanAsync :: Gearman a -> Gearman ()
runGearmanAsync (Gearman action) = do
    c <- ask
    ac <- liftIO $ async $ runReaderT action c
    liftIO $ link ac

getHostAddress :: String -> String -> IO (Maybe N.AddrInfo)
getHostAddress host port = do
    ai <- N.getAddrInfo hints (Just host) (Just port)
    case ai of
        (x:_) -> return $ Just x
        [] -> return Nothing
  where
    hints = Just $ N.defaultHints {
        N.addrProtocol = 6,
        N.addrFamily   = N.AF_INET,
        N.addrFlags    = [ N.AI_NUMERICSERV ]
    }

-- | connect attempts to connect to the supplied hostname and port.
connect :: String -> String -> IO (Either GearmanError Connection)
connect host port = do
    sock <- N.socket N.AF_INET N.Stream 6 -- Create new ipv4 TCP socket.
    ai <- getHostAddress host port
    case ai of
        Nothing -> return $ Left $ "could not resolve address" ++ host
        Just x  -> do
            N.connect sock $ N.addrAddress x
            return $ Right $ Connection host port sock

-- | echo tests a Connection by sending (and waiting for a response to) an
--   echo packet.
echo :: Connection -> [L.ByteString] ->  IO (Maybe GearmanError)
echo Connection{..} payload = do
    sent <- send sock $ L.toStrict req
    let expected = fromIntegral (S.length $ L.toStrict req)
    if sent == expected
    then do
        rep <- recv sock 8
        case S.length rep of
            8 -> return Nothing
            x -> return $ Just $ recvError x
    else return $ Just $ sendError sent
  where
    req = buildEchoReq payload
    sendError b = concat ["echo failed: only sent ", show b, " bytes"]
    recvError b = concat ["echo failed: only received ", show b, " bytes"]

-- |Clean up the Gearman monad and close the connection.
cleanup :: Connection -> IO ()
cleanup Connection{..} = N.sClose sock

-- |Execute an action inside the Gearman monad, connecting to the
-- provided host and port.
runGearman :: String -> String -> Gearman a -> IO a
runGearman host port (Gearman action) = do
    c <- connect host port
    case c of
        Left x  -> error (show x)
        Right x -> do
            r <- runReaderT action x
            liftIO $ cleanup x
            return r

sendPacketIO :: Connection -> L.ByteString -> IO (Maybe GearmanError)
sendPacketIO Connection{..} packet = do
    let expected = fromIntegral (S.length $ L.toStrict packet)
    sent <- send sock $ L.toStrict packet
    return $ if sent == expected
        then Nothing
        else Just $ sendError sent
  where
    sendError b = concat ["send failed: only sent ", show b, " bytes"]

-- |Send a packet to the Gearman server. Treats bytes as opaque, does
-- not do any serialisation.
sendPacket :: L.ByteString -> Gearman (Maybe GearmanError)
sendPacket packet = do
    connection <- ask
    liftIO $ sendPacketIO connection packet

-- |Receive n bytes from the Gearman server.
recvBytes :: Int -> Gearman (Either GearmanError S.ByteString)
recvBytes 0 = return $ Right ""
recvBytes n = do
    Connection{..} <- ask
    msg <- liftIO $ catch (eitherRecvFrom sock n) handleFailure
    case msg of
        Left err -> return $ Left err
        Right (bytes, _) -> return $ Right bytes
  where
    eitherRecvFrom sock n = do
        result <- recvFrom sock n
        return $ Right result
    handleFailure e = return $ Left $ show (e :: IOException)

-- Must restart connection if this fails.
recvPacket :: PacketDomain -> Gearman (Either GearmanError GearmanPacket)
recvPacket domain = do
    Connection{..} <- ask
    magicPart      <- recvBytes 4
    packetTypePart <- recvBytes 4
    dataSizePart   <- recvBytes 4
    let headerParts = [magicPart, packetTypePart, dataSizePart]
    let errs = lefts headerParts
    if not $ null errs
    then return $ Left $ "recvPacket failed to receieve header. Errors: " ++ concatMap show errs
    else do
        let [magicPart', packetTypePart', dataSizePart'] = rights headerParts
        let dataSize = parseDataSize $ L.fromStrict dataSizePart'
        argsPart <- if dataSize > 0
                    then recvBytes dataSize
                    else return $ Right ""
        case argsPart of
            Left err -> return $ Left $ "recvPacket failed to receive payload: " ++ err
            Right argsPart' ->
                return $ parsePacket domain (L.fromStrict magicPart') (L.fromStrict packetTypePart') (L.fromStrict dataSizePart') (L.fromStrict argsPart')
