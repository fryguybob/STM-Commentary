% GHC STM Notes
% Ryan Yates
% 1-2-2013

# Introduction

This document give an overview of the runtime system (RTS) support for
GHC's STM implementation.  Specifically we look at the case where fine
grain locking is used (`STM_FG_LOCKS`).

Some details about the implementation can be found in the papers 
["Composable Memory Transactions"][composable]
and ["Transactional memory with data invariants"][invariant].  Additional 
details can be found in the Harris et al book
["Transactional memory"][HarrisBook].  Some analysis on performance can be
found in the paper ["The Limits of Software Transactional Memory"][limits]
though this work only looks at the coarse grain lock version.
Many of the other details here are gleaned from the comments in the source code.

# Background

TODO: fill in enough background details and links, a good starting point is
here: <http://hackage.haskell.org/trac/ghc/wiki/Commentary/Compiler/GeneratedCode>

## Definitions

`Capability`

:   Corresponds to a CPU.  The number of capabilities should match the number of
    CPUs.  See [Capabilities][cap].

`TSO`

:   Thread State Object.  The state of a Haskell thread.  See [Thread State Objects][tso].

Heap object

:   Objects on the heap all take the form of an `StgClosure` structure with a 
    header pointing and a payload of data.  The header points to code and an 
    info table.  See [Heap Objects][heap].

# Overview of Features

TODO: code examples in all of the subsections of the overview.

At the high level, transactions are computations that read and write to `TVar`s
with changes only being committed atomically after seeing a consistent view of
memory.  Transactions can also be composed together, building new transactions
out of existing transactions.  In the RTS each transaction keeps a record of
its interaction with the `TVar`s it touches in a `TRec`.  A pointer to this
record is stored in the TSO that is running the transaction.

## Reading and Writing

The semantics of a transaction require that when a `TVar` is read in a transaction,
ts value will stay the same for the duration of execution.  Similarly a write
to a `TVar` will keep the same value for the duration of the transaction.  The
transaction itself, however, from the perspective of other threads can apply
all of its effects in one moment.  That is, other threads cannot see intermediate
states of the transaction, so it is as if all the effects happen in a single moment.

As a simple example we can consider a transaction that transfers value between two accounts:

~~~~{.haskell}
transfer :: Int -> TVar Int -> TVar Int -> STM ()
transfer v a b = do
    x <- readTVar a
    y <- readTVar b
    writeTVar a (x - v)
    writeTVar b (y + v)
~~~~

No other thread can observe the value `x - v` in `a` without also observing `y + v` in `b`.

## Blocking

Transactions can choose to block until changes are made to `TVar`s that allow
it to try again.  This is enabled with an explicit `retry`.  Note that when
changes are made the transaction is restarted from the beginning.

Continuing the example, we can choose to block when there are insufficient funds:

~~~~{.haskell}
transferBlocking :: Int -> TVar Int -> TVar Int -> STM ()
transferBlocking v a b = do
    x <- readTVar a
    y <- readTVar b
    if x < v
      then retry
      else do
              writeTVar a (x - v)
              writeTVar b (y + v)
~~~~

## Choice

Any blocking transaction can be composed with `orElse` to choose an alternative
transaction to run instead of blocking.  The `orElse` primitive operation creates
a nested transaction and if this first transaction executes `retry`, the effects
of the nested transaction are rolled back and the alternative transaction is
executed.  This choice is biased towards the first parameter.  A validation failure
in the first branch aborts the entire transaction, not just the nested part.
An explicit `retry` is the only mechanism that gives partial rollback.

We now can choose the account that has enough funds for the transfer: 

~~~~{.haskell}
transferChoice :: Int -> TVar Int -> TVar Int -> TVar Int -> STM ()
transferChoice v a a' b = do
    transferBlocking v a b `orElse` transferBlocking v a' b
~~~~

## Data Invariants

Invariants support checking global data invariants beyond the atomicity
transactions demand.  For instance, a transactional linked list (written
correctly) will never have an inconsistent structure due to the atomicity of
updates.  It is no harder to maintain this property in a concurrent setting
then in a sequential one with STM.  It may be desired, however, to make
statements about the consistency of the *data* in a particular a sorted linked
list is sorted, not because of the structure (where the `TVar`s point to) but
instead because of the data in the structure (the relation between the data in
adjacent nodes).  Global data invariant checks can be introduced with the
`always` operation which demands that the transaction it is given results in
`True` very every transaction that is committed globally.

We can use data invariants to guard against negative balances:

~~~~{.haskell}
newNonNegativeAccount :: STM (TVar Int)
newNonNegativeAccount = do
    t <- newTVar 0
    always $ do
        x <- readTVar t
        return (x > 0)
    return t
~~~~

# Overview of the Implementation

## Reading

The `TRec` will have an entry for each accessed `TVar`.  When a read is
attempted we first search the `TRec` for an existing entry.  If it is found, we
use that local view of the variable.  On the first read of the variable, a new
entry is allocated and the value of the variable is read and stored locally.
The original `TVar` does not need to be accessed again for its value until a
validation check is needed.

In the coarse grain version, the read is done without synchronization.
With the fine grain lock, the lock variable is the `current_value` of the
`TVar` structure.  While reading an inconsistent value is an issue that can be
resolved later, reading a value that indicates a lock and handing that value
to code that expects a different type of heap object will almost certainly lead to
a runtime failure.  To avoid this the fine grain lock version of the code will
spin if the value read is a lock, waiting to observe the lock released with an
appropriate pointer to a heap object.

## Writing

Writing to a `TVar` requires that the variable first be in the `TRec`.  If it
is not currently in the `TRec`, a read of the `TVar`'s value is stored in a new
entry (this value will be used to validate and ensure that no updates were made
concurrently to this variable).

In both the fine grain and coarse grain lock versions of the code no
synchronization is needed to perform the write as the value is stored locally
in the `TRec` until commit time.

## Validation

Before a transaction can make its effects visible to other threads it must
check that it has seen a consistent view of memory while it was executing.
Most of the work is done in `validate_and_acquire_ownership` by checking that
`TVar`s hold their expected values.

For the coarse grain lock version the lock is held before entering
`validate_and_acquire_ownership` through the writing of values to `TVar`s.
With the fine grain lock, validation acquires locks for the write set and reads
a version number consistent with the expected value for each `TVar` in the read
set.  After all the locks for writes have been acquired, The read set is
checked again to see if each value is still the expected value and the version
number still matches (`check_read_only`).

## Committing

Before committing, each invariant associated with each accessed `TVar` needs to
be checked by running the invariant transaction with its own `TRec`.  The read
set for each invariant is merged into the transaction as those reads must be
included in the consistency check.  The `TRec` is then validated.  If
validation fails, the transaction must start over from the beginning after
releasing all locks.  In the case of the coarse grain lock validation and
commit are in a critical section protected by the global STM lock.  Updates to
`TVar`s proceeds while holding the global lock.

With the fine grain lock version when validation, including any read-only
phase, succeeds, two properties will hold that give the desired atomicity:

1)  Validation has witnessed all `TVar`s with their expected value.
2)  Locks are held for all of the `TVar`s in the write set.

Commit can proceed to increment each locked `TVar`'s `num_updates` field and
unlock by writing the new value to the `current_value` field.  While these
updates happen one-by-one, any attempt to read from this set will spin while
the lock is held.  Any reads made before the lock was acquired will fail to
validate as the number of updates will change.

## Aborting

Aborting is simply throwing away changes that are stored in the `TRec`.

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

For each update entry (a write to a `TVar`) in the `TRec` 

Note that there is a `check` in the `stm` package in `Control.Monad.STM` which matches
the `check` from the [beauty] chapter of "Beautiful code":

    check :: Bool -> STM ()
    check b = if b then return () else retry

It requires no additional runtime support.  If it is a transaction that produces the 
`Bool` argument it will be committed (when `True`) and it is only a one time check, not
an invariant that will be checked at commits.

## Watch Queues

With `retry`, `orElse`, and invariants we have conditions beyond a consistent
view of memory that need to hold for the transaction to commit. To efficiently
resolve failing conditions, transactions are not immediately restarted but wait
for something to change that might make it possible to succeed on a subsequent
attempt.  This is done using the watch queue associated with each `TVar`.
The watch queue contains invariants (when ???) and TSOs.  When a transaction
executes `retry` and there is no `CATCH_RETRY_FRAME` (from an `orElse`) above it
(it has exhausted all the alternatives) the transaction will wait by calling
`stmWait`.  This verifies that the transaction is valid (acquiring locks for all
`TVar`s in the `TRec`) and if valid adds the transaction's TSO to each `TVar`s
watch queue.  When another thread commits a transaction that writes to a `TVar`,
each TSO on the watch queue is woken (scheduled for running on the current 
capability).

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
    "Heap Objects"

[tso]: http://hackage.haskell.org/trac/ghc/wiki/Commentary/Rts/Storage/HeapObjects#ThreadStateObjects
    "Thread State Objects"

[cap]: http://hackage.haskell.org/trac/ghc/wiki/Commentary/Rts/Scheduler#Capabilities
    "Capabilities"

[beauty]: http://research.microsoft.com/pubs/74063/beautiful.pdf
    "Beautiful Concurrency"

[beauty-soh]: https://www.fpcomplete.com/school/beautiful-concurrency
    "Beautiful Concurrency (interactive)"

[invariant]: http://research.microsoft.com/en-us/um/people/simonpj/papers/stm/stm-invariants.pdf
    "Transactional memory with data invariants"

[composable]: http://research.microsoft.com/en-us/um/people/simonpj/papers/stm/stm.pdf
    "Composable Memory Transactions"
    
[limits]: https://www.bscmsrc.eu/sites/default/files/cf-final.pdf
    "The Limits of Software Transactional Memory"
    
[HarrisBook]: http://www.morganclaypool.com/doi/abs/10.2200/s00272ed1v01y201006cac011
    "Transactional Memory"
    
## Bibliography

Harris, Tim, James Larus, and Ravi Rajwar. "Transactional memory." *Synthesis Lectures on Computer Architecture* 5.1 (2010): 1-263.

Jones, Simon Peyton. "Beautiful concurrency." *Beautiful Code: Leading Programmers Explain How They Think* (2007): 385-406.

Harris, Tim, et al. "Composable memory transactions." *Proceedings of the tenth ACM SIGPLAN symposium on Principles and practice of parallel programming.* ACM, 2005.

Perfumo, Cristian, et al. "The limits of software transactional memory (STM): dissecting Haskell STM applications on a many-core environment." *Proceedings of the 5th conference on Computing frontiers.* ACM, 2008.

Harris, Tim, and Simon Peyton Jones. "Transactional memory with data invariants." *First ACM SIGPLAN Workshop on Languages, Compilers, and Hardware Support for Transactional Computing (TRANSACT'06), Ottowa.* 2006.
