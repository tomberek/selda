{-# LANGUAGE GADTs, BangPatterns, OverloadedStrings, CPP #-}
-- | Encoding/decoding for PostgreSQL.
module Database.Selda.PostgreSQL.Encoding
  ( toSqlValue, fromSqlValue, fromSqlType
  , readInt, readBool
  ) where
#ifdef __HASTE__

toSqlValue, fromSqlValue, fromSqlType, readInt :: a
toSqlValue = undefined
fromSqlValue = undefined
fromSqlType = undefined
readInt = undefined

#else

import qualified Data.ByteString as BS
import Data.ByteString.Builder
import Data.ByteString.Char8 (unpack)
import qualified Data.ByteString.Char8 as BSC (map)
import qualified Data.ByteString.Lazy as LBS
import Data.Char (toLower)
import qualified Data.Text as Text
import Data.Text.Encoding
import Database.PostgreSQL.LibPQ (Oid (..), Format (..))
import Database.Selda.Backend
import Unsafe.Coerce

-- | OIDs for all types used by Selda.
blobType, boolType, intType, int32Type, int16Type, textType, doubleType,
  dateType, timeType, timestampType, nameType, varcharType :: Oid
boolType      = Oid 16
intType       = Oid 20
int32Type     = Oid 23
int16Type     = Oid 21
textType      = Oid 25
nameType      = Oid 19
doubleType    = Oid 701
dateType      = Oid 1082
timeType      = Oid 1266
timestampType = Oid 1184
blobType      = Oid 17
varcharType   = Oid 1043
uuidType      = Oid 2950

-- | Convert a parameter into an postgres parameter triple.
fromSqlValue :: Lit a -> Maybe (Oid, BS.ByteString, Format)
fromSqlValue (LBool b)     = Just (boolType, toBS $ if b then word8 1 else word8 0, Binary)
fromSqlValue (LInt n)      = Just (intType, toBS $ int64BE (fromIntegral n), Binary)
fromSqlValue (LDouble f)   = Just (doubleType, toBS $ int64BE (unsafeCoerce f), Binary)
fromSqlValue (LText s)     = Just (textType, encodeUtf8 $ Text.filter (/= '\0') s, Binary)
fromSqlValue (LDateTime s) = Just (timestampType, encodeUtf8 s, Text)
fromSqlValue (LTime s)     = Just (timeType, encodeUtf8 s, Text)
fromSqlValue (LDate s)     = Just (dateType, encodeUtf8 s, Text)
fromSqlValue (LUUID x)     = Just (uuidType, x, Binary)
fromSqlValue (LBlob b)     = Just (blobType, b, Binary)
fromSqlValue (LNull)       = Nothing
fromSqlValue (LJust x)     = fromSqlValue x
fromSqlValue (LCustom l)   = fromSqlValue l

-- | Get the corresponding OID for an SQL type representation.
fromSqlType :: SqlTypeRep -> Oid
fromSqlType TBool     = boolType
fromSqlType TInt      = intType
fromSqlType TFloat    = doubleType
fromSqlType TText     = textType
fromSqlType TDateTime = timestampType
fromSqlType TDate     = dateType
fromSqlType TTime     = timeType
fromSqlType TBlob     = blobType
fromSqlType TRowID    = intType
fromSqlType TUUID     = uuidType

-- | Convert the given postgres return value and type to an @SqlValue@.
toSqlValue :: Oid -> BS.ByteString -> SqlValue
toSqlValue t val
  | t == boolType    = SqlBool $ readBool (BSC.map toLower val)
  | t == intType     = SqlInt $ readInt val
  | t == int32Type   = SqlInt $ readInt val
  | t == int16Type   = SqlInt $ readInt val
  | t == doubleType  = SqlFloat $ read (unpack val)
  | t == blobType    = SqlBlob $ pgDecode val
  | t == uuidType    = SqlBlob $ decodeUuid val
  | t `elem` textish = SqlString (decodeUtf8 val)
  | otherwise        = error $ "BUG: result with unknown type oid: " ++ show t
  where
    decodeUuid = pgDecode . BS.append "\\x" . BS.filter (/= 45)
    -- PostgreSQL hex strings are of the format \xdeadbeefdeadbeefdeadbeef...
    pgDecode s
      | BS.index s 0 == 92 && BS.index s 1 == 120 =
        BS.pack $ go $ BS.drop 2 s
      | otherwise =
        error $ "bad blob string from postgres: " ++ show s
      where
        hex n x =
          case BS.index x n of
            c | c >= 97   -> c - 87 -- c >= 'a'
              | c >= 65   -> c - 55 -- c >= 'A'
              | otherwise -> c - 48 -- c is numeric
        go x
          | BS.length x >= 2 = (16*hex 0 x + (hex 1 x)) : go (BS.drop 2 x)
          | otherwise        = []
    textish = [textType, timestampType, timeType, dateType, nameType, varcharType]

-- | Attempt to make sense of a bool-ish value.
--   Note that values should all be in lowercase.
readBool :: BS.ByteString -> Bool
readBool "f"     = False
readBool "0"     = False
readBool "false" = False
readBool "n"     = False
readBool "no"    = False
readBool "off"   = False
readBool _       = True

-- | Read an integer from a strict bytestring.
--   Assumes that the bytestring does, in fact, contain an integer.
readInt :: BS.ByteString -> Int
readInt s
  | BS.head s == asciiDash = negate $! go 1 0
  | otherwise              = go 0 0
  where
    !len = BS.length s
    !asciiZero = 48
    !asciiDash = 45
    go !i !acc
      | len > i   = go (i+1) (acc * 10 + fromIntegral (BS.index s i - asciiZero))
      | otherwise = acc

-- | Reify a builder to a strict bytestring.
toBS :: Builder -> BS.ByteString
toBS = unChunk . toLazyByteString

-- | Convert a lazy bytestring to a strict one.
--   Avoids the copying overhead of 'LBS.toStrict' when there's only a single
--   chunk, which should always be the case when serializing single parameters.
unChunk :: LBS.ByteString -> BS.ByteString
unChunk bs =
  case LBS.toChunks bs of
    [bs'] -> bs'
    bss   -> BS.concat bss
#endif
