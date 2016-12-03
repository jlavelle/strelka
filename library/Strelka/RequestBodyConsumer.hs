module Strelka.RequestBodyConsumer where

import Strelka.Prelude
import Strelka.Model
import qualified Data.Attoparsec.ByteString
import qualified Data.Attoparsec.Text
import qualified Data.Attoparsec.Types
import qualified Data.ByteString
import qualified Data.ByteString.Lazy
import qualified Data.ByteString.Builder
import qualified Data.Text
import qualified Data.Text.Encoding
import qualified Data.Text.Encoding.Error
import qualified Data.Text.Lazy
import qualified Data.Text.Lazy.Encoding
import qualified Data.Text.Lazy.Builder


newtype RequestBodyConsumer a =
  RequestBodyConsumer (IO ByteString -> IO a)
  deriving (Functor)

-- |
-- Fold with support for early termination,
-- which is interpreted from Left.
foldBytesTerminating :: (a -> ByteString -> Either a a) -> a -> RequestBodyConsumer a
foldBytesTerminating step init =
  RequestBodyConsumer consumer
  where
    consumer getChunk =
      recur init
      where
        recur state =
          getChunk >>= onChunk
          where
            onChunk chunk =
              if Data.ByteString.null chunk
                then return state
                else case step state chunk of
                  Left newState -> return newState
                  Right newState -> recur newState

-- |
-- Fold with support for early termination,
-- which is interpreted from Left.
foldTextTerminating :: (a -> Text -> Either a a) -> a -> RequestBodyConsumer a
foldTextTerminating step init =
  fmap snd (foldBytesTerminating bytesStep bytesInit)
  where
    bytesInit =
      (decode, init)
      where
        decode =
          Data.Text.Encoding.streamDecodeUtf8With Data.Text.Encoding.Error.lenientDecode
    bytesStep (!decode, !state) bytesChunk =
      case decode bytesChunk of
        Data.Text.Encoding.Some textChunk leftovers nextDecode ->
          if Data.Text.null textChunk
            then Right (nextDecode, state)
            else bimap ((,) nextDecode) ((,) nextDecode) (step state textChunk)

foldBytes :: (a -> ByteString -> a) -> a -> RequestBodyConsumer a
foldBytes step init =
  RequestBodyConsumer consumer
  where
    consumer getChunk =
      recur init
      where
        recur state =
          getChunk >>= onChunk
          where
            onChunk chunk =
              if Data.ByteString.null chunk
                then return state
                else recur (step state chunk)

-- |
-- A UTF8 text chunks decoding consumer.
foldText :: (a -> Text -> a) -> a -> RequestBodyConsumer a
foldText step init =
  fmap fst (foldBytes bytesStep bytesInit)
  where
    bytesInit =
      (init, Data.Text.Encoding.streamDecodeUtf8With Data.Text.Encoding.Error.lenientDecode)
    bytesStep (!state, !decode) bytesChunk =
      case decode bytesChunk of
        Data.Text.Encoding.Some textChunk leftovers nextDecode ->
          (nextState, nextDecode)
          where
            nextState =
              if Data.Text.null textChunk
                then state
                else step state textChunk

{- |
Similar to "Foldable"\'s 'foldMap'.
-}
build :: Monoid a => (ByteString -> a) -> RequestBodyConsumer a
build proj =
  foldBytes (\l r -> mappend l (proj r)) mempty

bytes :: RequestBodyConsumer ByteString
bytes =
  fmap Data.ByteString.Lazy.toStrict lazyBytes

lazyBytes :: RequestBodyConsumer Data.ByteString.Lazy.ByteString
lazyBytes =
  fmap Data.ByteString.Builder.toLazyByteString bytesBuilder

bytesBuilder :: RequestBodyConsumer Data.ByteString.Builder.Builder
bytesBuilder =
  build Data.ByteString.Builder.byteString

text :: RequestBodyConsumer Text
text =
  fmap Data.Text.Lazy.toStrict lazyText

lazyText :: RequestBodyConsumer Data.Text.Lazy.Text
lazyText =
  fmap Data.Text.Lazy.Builder.toLazyText textBuilder

textBuilder :: RequestBodyConsumer Data.Text.Lazy.Builder.Builder
textBuilder =
  fmap fst (foldBytes step init)
  where
    step (builder, decode) bytes =
      case decode bytes of
        Data.Text.Encoding.Some decodedChunk _ newDecode ->
          (builder <> Data.Text.Lazy.Builder.fromText decodedChunk, newDecode)
    init =
      (mempty, Data.Text.Encoding.streamDecodeUtf8)

-- |
-- Turn a bytes parser into an input stream consumer.
bytesParser :: Data.Attoparsec.ByteString.Parser a -> RequestBodyConsumer (Either Text a)
bytesParser parser =
  parserResult foldBytesTerminating (Data.Attoparsec.ByteString.Partial (Data.Attoparsec.ByteString.parse parser))

textParser :: Data.Attoparsec.Text.Parser a -> RequestBodyConsumer (Either Text a)
textParser parser =
  parserResult foldTextTerminating (Data.Attoparsec.Text.Partial (Data.Attoparsec.Text.parse parser))

parserResult :: Monoid i => (forall a. (a -> i -> Either a a) -> a -> RequestBodyConsumer a) -> Data.Attoparsec.Types.IResult i a -> RequestBodyConsumer (Either Text a)
parserResult fold result =
  fmap finalise (fold step result)
  where
    step result chunk =
      case result of
        Data.Attoparsec.Types.Partial chunkToResult ->
          Right (chunkToResult chunk)
        _ ->
          Left result
    finalise =
      \case
        Data.Attoparsec.Types.Partial chunkToResult ->
          finalise (chunkToResult mempty)
        Data.Attoparsec.Types.Done leftovers resultValue ->
          Right resultValue
        Data.Attoparsec.Types.Fail leftovers contexts message ->
          Left (fromString (intercalate " > " contexts <> ": " <> message))
