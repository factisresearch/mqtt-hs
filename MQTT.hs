{-# Language PatternSynonyms,
             OverloadedStrings,
             FlexibleContexts,
             DeriveDataTypeable #-}
{-|
Module: MQTT
Copyright: Lukas Braun 2014
License: GPL-3
Maintainer: koomi+mqtt@hackerspace-bamberg.de

A MQTT client library.

A simple example, assuming a broker is running on localhost
(needs -XOverloadedStrings):

>>> Just mqtt <- connect def
>>> let f t payload = putStrLn $ "A message was published to " ++ show t ++ ": " ++ show pyload
>>> subscribe mqtt NoConfirm "#" f
>>> publish mqtt Handshake False "some random/topic" "Some content!"
A message was published to "some random/topic": "Some content!"
-}
module MQTT
  ( -- * Creating connections
    connect
  , MQTT
  , MQTTConfig(..)
  , def
  , Will(..)
  , disconnect
  , reconnect
  , onReconnect
  , resubscribe
  -- * Subscribing and publishing
  , subscribe
  , unsubscribe
  , publish
  , QoS(..)
  , MsgType(..)
  -- * Sending and receiving 'Message's
  , send
  , addHandler
  , removeHandler
  , awaitMsg
  , module MQTT.Types
  ) where

import Control.Applicative
import Control.Concurrent

import Control.Exception hiding (handle)
import Control.Monad hiding (sequence_)
import Data.Attoparsec (parseOnly)
import Data.Bits ((.&.))
import Data.ByteString (hGet, ByteString)
import qualified Data.ByteString as BS
import Data.Foldable (for_, sequence_, traverse_)
import qualified Data.Map as M
import Data.Maybe (isJust)
import Data.Word
import Data.Text (Text)
import Data.Traversable (for)
import Data.Typeable (Typeable)
import Data.Unique
import Network
import Prelude hiding (sequence_)
import System.IO (Handle, hClose, hIsEOF)
import System.Timeout (timeout)

import MQTT.Types
import MQTT.Parser
import MQTT.Encoding
import qualified MQTT.Logger as L

-----------------------------------------
-- Interface
-----------------------------------------

-- | Abstract type representing a connection to a broker.
data MQTT
    = MQTT
        { config :: MQTTConfig
        , handle :: MVar Handle
        , handlers :: MVar (M.Map MsgType [(Unique, Message -> IO ())])
        , topicHandlers :: MVar [TopicHandler]
        , recvThread :: MVar ThreadId
        , reconnectHandler :: MVar (IO ())
        , keepAliveThread :: MVar ThreadId
        , sendSem :: Maybe QSem
        }

data TopicHandler
    = TopicHandler
        { thTopic :: Topic
        , thQoS :: QoS
        , thHandler :: Topic -> ByteString -> IO ()
        }

-- | The various options when establishing a connection.
data MQTTConfig
    = MQTTConfig
        { cHost :: HostName
        , cPort :: PortNumber
        , cClean :: Bool
        , cWill :: Maybe Will
        , cUsername :: Maybe Text
        , cPassword :: Maybe Text
        , cKeepAlive :: Maybe Int
        , cClientID :: Text
        , cConnectTimeout :: Maybe Int
        , cReconnPeriod :: Maybe Int
        , cLogger :: L.Logger
        }

-- | Defaults for 'MQTTConfig', connects to a server running on
-- localhost.
def :: MQTTConfig
def = MQTTConfig
        "localhost" 1883 True Nothing Nothing Nothing Nothing
        "mqtt-haskell" Nothing Nothing L.stdLogger

-- | A Will message is published by the broker if a client disconnects
-- without sending a DISCONNECT.
data Will
    = Will
        { wQoS :: QoS
        , wRetain :: Bool
        , wTopic :: Topic
        , wMsg :: Text
        }
    deriving (Eq, Show)


-- | Establish a connection.
connect :: MQTTConfig -> IO (Maybe MQTT)
connect conf = do
    h <- connectTo (cHost conf) (PortNumber $ cPort conf)
    mqtt <- MQTT conf
              <$> newMVar h
              <*> newMVar M.empty
              <*> newMVar []
              <*> newEmptyMVar
              <*> newEmptyMVar
              <*> newEmptyMVar
              <*> for (cKeepAlive conf) (const (newQSem 0))
    mCode <- handshake mqtt
    if mCode == Just 0
      then Just mqtt <$ do forkIO (recvLoop mqtt) >>= putMVar (recvThread mqtt)
                           forkIO (keepAliveLoop mqtt) >>=
                             putMVar (keepAliveThread mqtt)
                           addHandler mqtt PUBLISH (publishHandler mqtt)
      else Nothing <$ hClose h

-- | Send a 'Message' to the server.
send :: MQTT -> Message -> IO ()
send mqtt msg = do
    logInfo mqtt $ "Sending " ++ show (msgType (header msg))
    h <- readMVar (handle mqtt)
    writeTo h msg
    for_ (sendSem mqtt) signalQSem

handshake :: MQTT -> IO (Maybe Word8)
handshake mqtt = do
    let timeout' = maybe (fmap Just) (timeout . (* 1000000))
                     (cConnectTimeout (config mqtt))
    sendConnect mqtt
    msg <- timeout' (getMessage mqtt) `catch` \e ->
             Nothing <$ logError mqtt (show (e :: MQTTException) ++
                                      " while waiting for CONNACK")
    return $ case msg of
      Just (ConnAck code) -> Just code
      _ ->  Nothing

sendConnect :: MQTT -> IO ()
sendConnect mqtt = send mqtt connect
  where
    conf = config mqtt
    (willVH, willPL) = case cWill conf of
                         Just w  -> (Just (wQoS w, wRetain w)
                                    , Just (wTopic w, wMsg w))
                         Nothing -> (Nothing, Nothing)
    connect = Message
                (Header CONNECT False NoConfirm False)
                (Just (VHConnect (ConnectHeader
                                   "MQIsdp"
                                   3
                                   (cClean conf)
                                   willVH
                                   (isJust $ cUsername conf)
                                   (isJust $ cPassword conf)
                                   (maybe 0 fromIntegral $ cKeepAlive conf))))
                (Just (PLConnect (ConnectPL
                                   (MqttText $ cClientID conf)
                                   (fst <$> willPL)
                                   (MqttText . snd <$> willPL)
                                   (MqttText <$> cUsername conf)
                                   (MqttText <$> cPassword conf))))

-- | Block until a 'Message' of the given type, optionally with the given
-- 'MsgID', arrives.
awaitMsg :: MQTT -> MsgType -> Maybe MsgID -> IO Message
awaitMsg mqtt msgType mMsgID = do
    var <- newEmptyMVar
    handlerID <- addHandler mqtt msgType (putMVar var)
    let wait = do
          msg <- readMVar var
          if isJust mMsgID
            then if mMsgID == (varHeader msg >>= getMsgID)
                   then removeHandler mqtt msgType handlerID >> return msg
                   else wait
            else removeHandler mqtt msgType handlerID >> return msg
    wait

-- | Register a callback that gets invoked whenever a 'Message' of the
-- given 'MsgType' is received. Returns the ID of the handler which can be
-- passed to 'removeHandler'.
addHandler :: MQTT -> MsgType -> (Message -> IO ()) -> IO Unique
addHandler mqtt msgType handler = do
    id <- newUnique
    modifyMVar_ (handlers mqtt) $ \hs ->
      return $ M.insertWith' (++) msgType [(id, handler)] hs
    return id

-- | Remove the handler with the given ID.
removeHandler :: MQTT -> MsgType -> Unique -> IO ()
removeHandler mqtt msgType id = modifyMVar_ (handlers mqtt) $ \hs ->
    return $ M.adjust (filter ((/= id) . fst)) msgType hs

-- | Subscribe to a 'Topic' with the given 'QoS' and invoke the callback
-- whenever something is published to the 'Topic'. Returns the 'QoS' that
-- was granted by the broker (lower or equal to the one requested).
--
-- The 'Topic' may contain
-- <http://public.dhe.ibm.com/software/dw/webservices/ws-mqtt/mqtt-v3r1.html#appendix-a wildcars>.
-- The 'Topic' passed to the callback is the fully expanded version where
-- the message was actually published.
subscribe :: MQTT -> QoS -> Topic -> (Topic -> ByteString -> IO ())
          -> IO QoS
subscribe mqtt qos topic handler = do
    qosGranted <- sendSubscribe mqtt qos topic
    modifyMVar_ (topicHandlers mqtt) $ \hs ->
      return $ TopicHandler topic qosGranted handler : hs
    return qosGranted

sendSubscribe :: MQTT -> QoS -> Topic -> IO QoS
sendSubscribe mqtt qos topic = do
    msgID <- fromIntegral . hashUnique <$> newUnique
    send mqtt $ Message
                  (Header SUBSCRIBE False Confirm False)
                  (Just (VHOther msgID))
                  (Just (PLSubscribe [(topic, qos)]))
    msg <- awaitMsg mqtt SUBACK (Just msgID)
    -- TODO: fail better or verify with GADT
    let Just (PLSubAck [qosGranted]) = payload msg
    return qosGranted

-- | Unsubscribe from the given 'Topic' and remove any handlers.
unsubscribe :: MQTT -> Topic -> IO ()
unsubscribe mqtt topic = do
    modifyMVar_ (topicHandlers mqtt) $ return . filter ((== topic) . thTopic)
    msgID <- fromIntegral . hashUnique <$> newUnique
    send mqtt $ Message
                  (Header UNSUBSCRIBE False Confirm False)
                  (Just (VHOther msgID))
                  (Just (PLUnsubscribe [topic]))
    void $ awaitMsg mqtt UNSUBACK (Just msgID)

-- | Publish a message to the given 'Topic' at the requested 'QoS' level.
-- The payload can be any sequence of bytes, including none at all. The 'Bool'
-- parameter decides if the server should retain the message for future
-- subscribers to the topic.
--
-- The 'Topic' must not contain
-- <http://public.dhe.ibm.com/software/dw/webservices/ws-mqtt/mqtt-v3r1.html#appendix-a wildcards>.
publish :: MQTT -> QoS -> Bool -> Topic -> ByteString -> IO ()
publish mqtt qos retain topic body = do
    msgID <- if qos > NoConfirm
               then Just . fromIntegral . hashUnique <$> newUnique
               else return Nothing
    send mqtt $ Message
                  (Header PUBLISH False qos retain)
                  (Just (VHPublish (PublishHeader topic msgID)))
                  (Just (PLPublish body))
    case qos of
      NoConfirm -> return ()
      Confirm   -> void $ awaitMsg mqtt PUBACK msgID
      Handshake -> do
        void $ awaitMsg mqtt PUBREC msgID
        send mqtt $ Message
                      (Header PUBREL False Confirm False)
                      (fmap VHOther msgID)
                      Nothing
        void $ awaitMsg mqtt PUBCOMP msgID

-- | Close the connection to the server.
disconnect :: MQTT -> IO ()
disconnect mqtt = do
    h <- takeMVar $ handle mqtt
    writeTo h $
      Message
        (Header DISCONNECT False NoConfirm False)
        Nothing
        Nothing
    readMVar (recvThread mqtt) >>= killThread
    readMVar (keepAliveThread mqtt) >>= killThread
    hClose h

-- | Try creating a new connection with the same config (retrying after the
-- specified amount of seconds has passed) and invoke 'cOnReconnect' once
-- a new connection has been established.
--
-- Does not terminate the old connection.
reconnect :: MQTT -> Int -> IO ()
reconnect mqtt period = do
    -- Other threads can't write while the MVar is empty
    _ <- takeMVar (handle mqtt)
    logInfo mqtt "Reconnecting..."
    -- Temporarily create a new MVar for the handshake so other threads
    -- don't write before the connection is fully established
    handleVar <- newEmptyMVar
    go (mqtt { handle = handleVar })
    readMVar handleVar >>= putMVar (handle mqtt)
    -- forkIO so recvLoop isn't blocked
    tryReadMVar (reconnectHandler mqtt) >>= traverse_ (void . forkIO)
    logInfo mqtt "Reconnect successfull"
  where
    -- try reconnecting until it works
    go mqtt' = do
        let conf = config mqtt
        connectTo (cHost conf) (PortNumber $ cPort conf)
          >>= putMVar (handle mqtt')
        mCode <- handshake mqtt'
        unless (mCode == Just 0) $ do
          takeMVar (handle mqtt')
          threadDelay (period * 10^6)
          go mqtt'
      `catch`
        \e -> do
            logWarning mqtt $ "reconnect: " ++ show (e :: IOException)
            threadDelay (period * 10^6)
            go mqtt'

-- | Register a callback that will be invoked when a reconnect has
-- happened.
onReconnect :: MQTT -> IO () -> IO ()
onReconnect mqtt io = do
    let mvar = reconnectHandler mqtt
    empty <- isEmptyMVar mvar
    unless empty (void $ takeMVar mvar)
    putMVar mvar io

resubscribe :: MQTT -> IO [QoS]
resubscribe mqtt = do
    ths <- readMVar (topicHandlers mqtt)
    mapM (\th -> sendSubscribe mqtt (thQoS th) (thTopic th)) ths

maybeReconnect :: MQTT -> IO ()
maybeReconnect mqtt = do
    catch
      (readMVar (handle mqtt) >>= hClose)
      (const (pure ()) :: IOException -> IO ())
    for_ (cReconnPeriod $ config mqtt) $ reconnect mqtt


-----------------------------------------
-- Logger utility functions
-----------------------------------------

logInfo :: MQTT -> String -> IO ()
logInfo mqtt = L.logInfo (cLogger (config mqtt))

logWarning :: MQTT -> String -> IO ()
logWarning mqtt = L.logWarning (cLogger (config mqtt))

logError :: MQTT -> String -> IO ()
logError mqtt = L.logError (cLogger (config mqtt))


-----------------------------------------
-- Internal
-----------------------------------------

recvLoop :: MQTT -> IO ()
recvLoop mqtt = forever $ do
    h <- readMVar (handle mqtt)
    eof <- hIsEOF h
    if eof
      then do
        logError mqtt "EOF in recvLoop"
        maybeReconnect mqtt
      else do
        msg <- getMessage mqtt
        hs <- M.lookup (msgType $ header msg) <$> readMVar (handlers mqtt)
        for_ hs $ mapM_ (forkIO . ($ msg) . snd)
  `catches`
    [ Handler $ \e -> do
        logError mqtt $ "recvLoop: Caught " ++ show (e :: IOException)
        maybeReconnect mqtt
    , Handler $ \e ->
        logWarning mqtt $ "recvLoop: Caught " ++ show (e :: MQTTException)
    ]

-- | Block on a semaphore that is signaled by 'send'. If a timeout occurs
-- while waiting, send a 'PINGREQ' to the server and wait for PINGRESP.
-- Ignores errors that occur while writing to the handle, reconnects are
-- initiated by 'recvLoop'.
--
-- Returns immediately if no Keep Alive is specified.
keepAliveLoop :: MQTT -> IO ()
keepAliveLoop mqtt =
    sequence_ (loop <$> cKeepAlive (config mqtt) <*> sendSem mqtt)
  where
    loop period sem = forever $ do
      rslt <- timeout (period * 1000000) $ waitQSem sem
      case rslt of
        Nothing -> (do send mqtt $
                        Message
                          (Header PINGREQ False NoConfirm False)
                          Nothing
                          Nothing
                       void $ awaitMsg mqtt PINGRESP Nothing)
                  `catch`
                    (\e -> logError mqtt $ "keepAliveLoop: " ++ show (e :: IOException))
        Just _ -> return ()

publishHandler :: MQTT -> Message -> IO ()
publishHandler mqtt msg@(Publish topic body) = do
    case msg of
      PubConfirm msgid -> send mqtt $
                  Message
                    (Header PUBACK False NoConfirm False)
                    (Just (VHOther msgid))
                    Nothing
      PubHandshake msgid -> do
          send mqtt $ Message
                        (Header PUBREC False NoConfirm False)
                        (Just (VHOther msgid))
                        Nothing
          awaitMsg mqtt PUBREL Nothing
          send mqtt $ Message
                        (Header PUBCOMP False NoConfirm False)
                        (Just (VHOther msgid))
                        Nothing
      _ -> return ()
    callbacks <- filter (matches topic . thTopic)
                   <$> readMVar (topicHandlers mqtt)
    for_ callbacks $ \th -> thHandler th topic body
publishHandler mqtt _ = return ()

getMessage :: MQTT -> IO Message
getMessage mqtt = do
    h <- readMVar (handle mqtt)
    headerByte <- hGet' h 1
    remaining <- getRemaining h 0
    rest <- hGet' h remaining
    let parseRslt = do
          header <- parseOnly mqttHeader headerByte
          parseOnly (body header (fromIntegral remaining)) rest
    case parseRslt of
      Left err -> logError mqtt ("Error while parsing: " ++ err) >>
                  throw (ParseError err)
      Right msg -> msg <$
        logInfo mqtt ("Received " ++ show (msgType (header msg)))

getRemaining :: Handle -> Int -> IO Int
getRemaining h n = go n 1
  where
    go acc fac = do
      b <- getByte h
      let acc' = acc + (b .&. 127) * fac
      if b .&. 128 == 0
        then return acc'
        else go acc' (fac * 128)

getByte :: Handle -> IO Int
getByte h = fromIntegral . BS.head <$> hGet' h 1

hGet' :: Handle -> Int -> IO BS.ByteString
hGet' h n = do
    bs <- hGet h n
    if BS.length bs < n
      then throw EOF
      else return bs

-- | Exceptions that may arise while parsing messages. A user should
-- never see one of these.
data MQTTException
    = EOF
    | ParseError String
    deriving (Show, Typeable)

instance Exception MQTTException where
