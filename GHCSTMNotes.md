% GHC STM Notes
% Ryan Yates
% 12-22-2012

# Introduction

This document give an overview of the runtime system (rts) support for
GHC's STM implementation.  Specifically we look at the case where fine
grain locking is used (`STM_FG_LOCKS`).

# Background

TODO: fill in enough background details and links, a good starting point is
here: <http://hackage.haskell.org/trac/ghc/wiki/Commentary/Compiler/GeneratedCode>

## Definitions

`Capability`

:   Corresponds to a CPU.  The number of capabilities should match the number of
    CPUs.  See [cap].

`TSO`

:   Thread State Object.  The state of a Haskell thread.  See [tso].

Heap object

:   Objects on the heap all take the form of an `StgClosure` structure with a 
    header pointing and a payload of data.  The header points to code and an 
    info table.  See [heap].

# Overview

TODO: code examples in all of the subsections of the overview.

At the high level, transactions are computations that read and write to
`TVar`s with changes only being committed atomically and reads only
seeing consistent state.  Transactions can also
be composed together, building new transactions out of existing transactions.
In the RTS each transaction keeps a record of its interaction with the `TVar`s
it touches in a `TRec`.  A pointer to this record is stored in the TSO that is
running the transaction.

## Nesting

In addition, transactions can be "retried" with explicit `retry` that aborts
the transaciton and allows an alternative transaction to run on the current thread
with the `orElse` combinator or the same transaction can be run again when 
changes happen on another thread.

## Validation

Before a transaction can publish its effects it must check that it has
seen a consistant view of memory while it was executing.

## Committing

When we try to commit we check that invariants continue to hold, that
we have seen a consistent view of memory (validation), and that version
numbers have stayed consistent.  If all this holds we will have acquired
the locks for the affected `TVar`s and can atomically make visible changes
to memory (with respect to other transactions).

TODO: talk about the mechinism, locking, and have worked examples.

## Aborting

Aborting is simple in that we just throw away changes that are stored
in the `TRec`.

## Invariants

As a transaction is executing it can collect a queue of dynamically checked invariants.
These invariants are transactions that are never committed, but if they raise an exception
when executed successfully that exception will propagate out of the atomic frame.

`check#`

:   Primitive operation that adds an invariant (transaction to
    run) to the queue of the current `TRec` by calling `stmAddInvariantToCheck`.

`checkInv :: STM a -> STM ()`

:   A wrapper for `check#` (to give it the `STM` type).

`alwaysSucceeds :: STM a -> STM ()`

:   This is the `check` from the "Transactional memory with data invariants" paper.  
    The action immediately runs, wrapped in a nested transaction so that it
    will never commit but will have an opportunity to raise an exception.
    If successful, the originally passed action is added to the invariant queue. 

`always :: STM Bool -> STM ()`

:   Takes an `STM` action that results in a `Bool` and adds an invariant that 
    throws an exception when the result of the transaction is `False`.

The bookkeeping for invariants is in each `TRec`s `invariants_to_check` queue and 
the `StgAtomicallyFrame`s `next_invariant_to_check` field.  Each invariant is in 
a `StgAtomicInvariant` structure that includes the `STM` action, the `TRec` where
it was last executed, and a lock (TODO: why a lock?).  This is added to the current
`TRec`s queue when `check#` is executed.

When a transaction completes, execution will reach the `stg_atomically_frame` and
the `TRec`s `enclosing_trec` will be `NO_TREC` (a nested transaction would have a 
`stg_catch_retry_frame` before the `stg_atomically_frame` to handle cases
of non-empty `enclosing_trec`).  The frame
will then check the invariants by collecting the invariants it needs to check
with `stmGetInvariantsToCheck`, dequeuing each, executing, and when (or if) we get
back to the frame aborting the invariant action (if it failed, we would not get here
due to an exception, if it succeeds we do not want its effects).  Once all the 
invariants have been checked, the frame will be attempt to commit.

TODO: Explain how `stmGetInvariantsToCheck` works.

Note that there is a `check` in the `stm` package in `Control.Monad.STM` which matches
the `check` from the "Beautiful concurrency" chapter of "Beautiful code" [beauty]:

    check :: Bool -> STM ()
    check b = if b then return () else retry

It requires no additional runtime support.  If it is a transaction that produces the 
`Bool` argument it will be committed (when `True`) and it is only a one time check, not
an invariant that will be checked at commits.

## Watch Queues

With `retry`, `orElse`, and invariants we have conditions beyond a consistent
view of memory that need to hold for the transaction to commit. To efficiently
resolve these conditions transactions are not immediately
restarted when they do not hold, but wait for something to change that might 
make it possible to succeed on a subsequent attempt.

TODO: add details about watch queues.

## Fine Grain Locking

The locks in fine grain locking (`STM_FG_LOCKS`) are at the `TVar`
level and are implemented by placing the locking thread's `TRec` in
the `TVar`s current value using a compare and swap (`lock_tvar`).  The
value observed when locking is returned by `lock_tvar`.  To test if a
`TVar` is locked the value is inspected to see if it is a `TRec`
(checking that the closure's info table pointer is to
`stg_TREC_HEADER_info`).  If a `TRec` is found `lock_tvar` will spin
reading the `TVar`s current value until it is not a `TRec` and then
attempt again to obtain the lock.  Unlocking is simply a write of the
current value of the `TVar`.  There is also a conditional lock
`cond_lock_tvar` which will obtain the lock if the `TVar`s current
value is the given expected value.  If the `TVar` is already locked
this will not be the case (the value would be a `TRec`) and if the
`TVar` has been updated to a new (different) value then locking will
fail because the value does not match the expected value.  A compare
and swap is used for `cond_lock_tvar`.

# Code Reference

TODO: flesh out these notes.

## Structures

The structures used for STM are found in `includes/rts/storage/Closures.h`.

`StgTVarWatchQueue`

:   Doubly-linked queue of `StgClosure` (either `StgTSO` or `StgAtomicInvariant`).

`StgTVar`

:   Current value (`StgClosure`), a watch queue, and number of updates.

`StgAtomicInvariant`

:   Code (`StgClosure`), last execution (`StgTRecHeader`), lock (`StgWord`).

`TRecEntry`

:   Pointer to a `StgTVar`, expected value (`StgClosure`), new value
    (`StgClosure`), and number of updates.

`StgTRecChunk`

:   Singly-linked list of chunks, next entry index, and an array of
    `TRecEntry`s (size `TREC_CHUNK_NUM_ENTRIES = 16`)

`TRecState`

:   Enumeration: active, condemned, committed, aborted, or waiting.

`StgInvariantCheckQueue`

:   Singly-linked list of invariants (`StgAtomicInvariant`), and owned
    executions (`StgTRecHeader`).

`StgTRecHeader_`

:   Enclosing transactional record (`StgTRecHeader_`, nesting?), current chunk
    (`StgTRecChunk`), invariants to check (`StgInvariantCheckQueue`), and
    state.  When `t->enclosing_trec` is `NO_TREC` then `t` is a top-level
    transaction.  Otherwise 't' is a nested transaction and has a parent.

`StgAtomicallyFrame`

:   Code, next invariant to check (`StgTVarWatchQueue`), and result (`StgClosure`).

`StgCatchSTMFrame`

:   Code and handler.

`StgCatchRetryFrame`

:   First code, alternate code, and flag that is true if running alternate code.

## C functions

`rts/STM.c`

And now STM functions.

`lock_stm` and `unlock_stm`

:   These do nothing as they represent the coarse grain lock code path.

`lock_tvar` and `unlock_tvar`

:   When a `TVar` is locked its current value is replaced with the owning
    `TRec`.  Acquiring the lock is done by first checking that the value is
    not a `TRec`, then using compare and swap with that value and the `TRec`
    that wants to acquire the lock.  If the value has change before the 
    `cas` try again.  Unlocking simply puts a non-`TRec` value in the `TVar`.

`revert_ownership`

:   Releases locks on `TVar`s, restoring their expected values (which were
    stashed in the lock holding `TRec`).

`validate_and_acquire_ownership`

:   Takes an active, waiting or condemned `TRec` and checks that each `TVar` 
    in the record holds the `TRec`'s expected value.  When called during
    commit, update `TVar`s (those written to) are locked.  When called from
    wait, all `TVar`s are locked.  The locks are released if a discrepancy
    is found.  As the read only `TVar`s are encountered (those where the
    record's expected value matches the "new" value) the `TVar`s number of
    updates is written to the `TRec`.
    
    In the end, if `validate_and_acquire_ownership` returns true, then the
    record is consistent, the number of updates on any read only is 
    recorded, and locks are held for every write `TVar`.  If any 
    inconsistency is seen (a `TVar`'s current value doesn't match the `TRec`'s
    expected value) or a lock is held (same check as locks overwrite
    current value) false will be returned.

`check_read_only`

:   Checks that the read only entries in the `TRec` have the same number of 
    updates as the `TVar`s themselves.

`getToken`

:   Version numbers are checked for overflow by keeping a global count of 
    transactions (`max_commits`) and checking it for overflow in commit.
    The global count is incremented in batches when a per capability commit
    count reaches zero (from 1024).

`stmStartTransaction`

:   Consumes a global version number with `getToken` and allocates a new
    `TRec`.

TODO: Finish reference.

## Cmm Code

The higher level Haskell code calls several primitive operations written in GHC Cmm.
The code for 

`rts/primops.cmm`

TODO: primop details.

## Supporting Code

TODO: schedule, GC, and exception details.

`rts/Schedule.c`

`rts/RaiseAsync.c`



[heap]: http://hackage.haskell.org/trac/ghc/wiki/Commentary/Rts/Storage/HeapObjects

[tso]: http://hackage.haskell.org/trac/ghc/wiki/Commentary/Rts/Storage/HeapObjects#ThreadStateObjects

[cap]: http://hackage.haskell.org/trac/ghc/wiki/Commentary/Rts/Scheduler#Capabilities

[beauty]: http://research.microsoft.com/pubs/74063/beautiful.pdf

[invariant]: http://research.microsoft.com/en-us/um/people/simonpj/papers/stm/stm-invariants.pdf
