{-# LANGUAGE ConstraintKinds, DataKinds, GeneralizedNewtypeDeriving #-}
module Info
( DefaultFields
, HasDefaultFields
, Range(..)
, byteRange
, setByteRange
, Category(..)
, category
, setCategory
, SourceSpan(..)
, SourcePos(..)
, SourceSpans(..)
, sourceSpan
, setSourceSpan
, SourceText(..)
, sourceText
) where

import Data.Record
import Prologue
import Category
import Range
import SourceSpan
import Data.Aeson

-- | The default set of fields produced by our parsers.
type DefaultFields = '[ Range, Category, SourceSpan ]

-- | A type alias for HasField constraints commonly used throughout semantic-diff.
type HasDefaultFields fields = (HasField fields Category, HasField fields Range, HasField fields SourceSpan)

newtype SourceText = SourceText { unText :: Text }
  deriving (Show, ToJSON)

byteRange :: HasField fields Range => Record fields -> Range
byteRange = getField

setByteRange :: HasField fields Range => Record fields -> Range -> Record fields
setByteRange = setField

category :: HasField fields Category => Record fields -> Category
category = getField

setCategory :: HasField fields Category => Record fields -> Category -> Record fields
setCategory = setField

sourceText :: HasField fields SourceText => Record fields -> SourceText
sourceText = getField

sourceSpan :: HasField fields SourceSpan => Record fields -> SourceSpan
sourceSpan = getField

setSourceSpan :: HasField fields SourceSpan => Record fields -> SourceSpan -> Record fields
setSourceSpan = setField
