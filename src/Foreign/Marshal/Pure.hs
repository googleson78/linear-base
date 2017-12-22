{-# LANGUAGE GADTs #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | This module introduces primitives to /safely/ store manually managed data
-- (that is not managed by the GC). The benefit of manually managed data is that
-- it does not add to the GC pressure, and help ensure predictable latency
-- (/e.g./ in distributed applications). The cost is that memory management is
-- much more explicit: the programmer has to allocate and free memory
-- manually. Safety (in particular that every pointer is freed) is enforced by
-- linear types, which constrain usage, in particular sharing. Manually managed
-- data types also have less convenient syntax since they are not directly
-- supported by the compiler.
--
-- This module focuses on /pure/ manually managed data. That is data types like
-- standard Haskell. The only difference is that their lifetime is not managed
-- by the GC. Despite calling @malloc@ and @free@ under the hood, the entire API
-- is pure, and does not make calls in IO.
--
-- You can find example data structure implementation in the modules
-- @Foreign.List@ and @Foreign.Heap@ of the @example@ directory in the source
-- repository.
--
-- The allocation API is organised around a notion of memory 'Pool'. From the API
-- point of view, a pool serves as a source of linearity. That is: it ensures
-- that the allocation primitive need not take a continuation to delimit its
-- lifetime. Besides convenience, it avoids needlessly preventing functions from
-- being tail-recursive.
--
-- Pools play another role: resilience to exceptions. If an exception is raised,
-- all the data in the pool is deallocated. It does not, however, impose a stack
-- discipline: data in pools is normally freed by the destruction primitives of ,
-- only in case of exception are the pool deallocated in a stack-like
-- manner. Moreover, pool A can have data pointing to pool B, while at the same
-- time, pool B having data pointing to pool A.
--
-- The current API (ab)uses the 'Storable' abstraction for expediency. However,
-- this is not correct: even if we ignore the fact that the 'Storable' interface
-- is allowed to perform arbitrary 'IO', and that it makes no promise to
-- preserve linearity, 'Storable' is intended for C ABI-compatible
-- interface. Our goal is not interfacing with C, and, in fact, the internal
-- representation of manually managed data is not guaranteed to be sensible from
-- the point of view of C.
--
-- Functions in this module are meant to be qualified.

-- TODO: add link to an example in module header
-- TODO: change some words into link to the relevant API entry in the above description.

module Foreign.Marshal.Pure
  ( Pool
  , withPool
  , Box
  , alloc
  , deconstruct
  ) where

import Foreign.Marshal.Alloc
import Foreign.Ptr
import Foreign.Storable
import Prelude.Linear
import System.IO.Unsafe
import qualified Unsafe.Linear as Unsafe

-- TODO: ignoring exceptions for the moment. So that I can get some tests to
-- work first.

-- TODO: Briefly explain the Dupable-reader style of API, below, and fix
-- details.

-- | A 'Pool' can be 'consume'-ed. This is a no-op: it does not deallocate the
-- data in that pool. It cannot as there may still be accessible data in the
-- pool. It simply makes it impossible to add new data to the pool. It is
-- actually necessary to so consume a pool allocated with 'withPool' in order to
-- write a well-typed scope @Pool ->. Unrestricted b@.
data Pool = Pool

-- TODO: document individual functions

withPool :: (Pool ->. Unrestricted b) ->. Unrestricted b
withPool scope = scope Pool

instance Consumable Pool where
  consume Pool = ()

instance Dupable Pool where
  dup Pool = (Pool, Pool)

-- XXX: this indirection is possibly not necessary. It's here because the inner
-- Ptr must be unrestricted (in order to implement deconstruct at the moment).
-- | 'Box a' is the abstract type of manually managed data. It can be used as
-- part of data type definitions in order to store linked data structure off
-- heap. See @Foreign.List@ and @Foreign.Pair@ in the @examples@ directory of
-- the source repository.
data Box a where
  Box :: Ptr a -> Box a

-- XXX: if Box is a newtype, can be derived
instance Storable (Box a) where
  sizeOf _ = sizeOf (undefined :: Ptr a)
  alignment _ = alignment (undefined :: Ptr a)
  peek ptr = Box <$> (peek (castPtr ptr :: Ptr (Ptr a)))
  poke ptr (Box ptr') = poke (castPtr ptr :: Ptr (Ptr a)) ptr'

-- TODO: a way to store GC'd data using a StablePtr

-- TODO: reference counted pointer. Remarks: rc pointers are Dupable but not
-- Movable. In order to be useful, need some kind of borrowing on the values, I
-- guess. 'Box' can be realloced, but not RC pointers.

-- XXX: We brazenly suppose that the `Storable` API can be seen as exposing
-- linear functions. It's not very robust. This also ties in the next point.

-- TODO: Ideally, we would like to avoid having a boxed representation of the
-- data before a pointer is created. A better solution is to have a destination
-- passing-style API (but there is still some design to be done there). This
-- alloc primitive would then be derived (but most of the time we would rather
-- write bespoke constructors).
alloc :: forall a. Storable a => a ->. Pool ->. Box a
alloc a Pool =
    Unsafe.toLinear mkPtr a
  where
    mkPtr :: a -> Box a
    mkPtr a' = unsafeDupablePerformIO $ do
      ptr <- malloc
      poke ptr a'
      return (Box ptr)

deconstruct :: Storable a => Box a ->. a
deconstruct (Box ptr) = unsafeDupablePerformIO $ do
  res <- peek ptr
  free ptr
  return res
