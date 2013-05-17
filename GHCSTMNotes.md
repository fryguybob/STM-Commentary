% GHC STM Notes
% Ryan Yates
% 1-2-2013

# Introduction

This document give an overview of the runtime system (RTS) support for
GHC's STM implementation.  We will focus on the case where fine
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

This document assumes the reader is familiar with some general details of GHC's
execution and memory layout.  A good starting point for this information is can
be found here:
<http://hackage.haskell.org/trac/ghc/wiki/Commentary/Compiler/GeneratedCode>

## Definitions

### Useful RTS terms

`Capability`

:   Corresponds to a CPU.  The number of capabilities should match the number of
    CPUs.  See [Capabilities][cap].

TSO

:   Thread State Object.  The state of a Haskell thread.  See [Thread State Objects][tso].

Heap object

:   Objects on the heap all take the form of an `StgClosure` structure with a 
    header pointing and a payload of data.  The header points to code and an 
    info table.  See [Heap Objects][heap].

### Transactional Memory terms

Read set

:   The set of `TVar`s that are read, but not written to durring a transaction.

Write set

:   The set of `TVar`s that are written to durring a transaction.  In the
    code each written `TVar` is called an "update entry" in the transactional
    record.

Access set

:   All `TVar`s accessed durring the transaction.

While GHC's STM does not have a separate read set and write set these terms
are useful for discussion.

Retry

:   Here we will use the term retry exclusively for the blocking primitive in
    GHC's STM.  This should not be confused with the steps taken when a 
    transaction detects that it has seen an inconsistent view of memory and
    must start again from the beginning.

Failure

:   A failed transaction is one that has seen inconsistent state.  This should
    not be confused with a successful transaction that executes the `retry`
    primitive.

# Overview of Features

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

## Exceptions

Exceptions inside transactions should only propagate outside if the transaction
has seen a consistent view of memory.  Note that the semantics of exceptions
allow the exception itself to capture the view of memory from inside the
transaction, but this transaction is not committed.

# Overview of the Implementation

We will start this section by considering building GHC's STM with only the
features of reading and writing.  Then we will add `retry` then `orElse`
and finally data invariants.  Each of the subsequent features adds more
complexity to the implementation.  Taken all at once it can be difficult
to understand the subtlety of some of the design choices.

## Transactions that Read and Write.

With this simplified view we only support `newTVar`, `readTVar`, and `writeTVar`
as well as all the STM type class instances except `Alternative`.

### Transactional Record

The overall scheme of GHC's STM is to perform all the effects of a transaction
locally in the transactional record or `TRec`.  Once the transaction has
finished its work locally, a value based consistency check determines if the
values read for the entire access set are consistent.  This only needs to
consider the `TRec` and the main memory view of the access set as it is assumed
that main memory is always consistent.  This check also obtains locks for the
write set and with those locks we can update main memory and unlock.  Rolling
back the effects of a transaction is just forgetting the current `TRec` and
starting again.

The transactional record itself will have an entry for each transactional
variable that is accessed.  Each entry has a pointer to the `TVar` heap object
and a record of the value that the `TVar` held when it was first accessed.

### Starting

A transaction starts by initializing a new `TRec` (`stmStartTransaction`)
assigning the TSO's `trec` pointer to the new `TRec` then executing
the transaction's code.

(See [source:rts/PrimOps.cmm] `stg_atomicallyzh` and 
[source:rts/STM.c] `stmStartTransaction`).

### Reading

When a read is attempted we first search the `TRec` for an existing entry.  If
it is found, we use that local view of the variable.  On the first read of the
variable, a new entry is allocated and the value of the variable is read and
stored locally.  The original `TVar` does not need to be accessed again for its
value until a validation check is needed.

In the coarse grain version, the read is done without synchronization.
With the fine grain lock, the lock variable is the `current_value` of the
`TVar` structure.  While reading an inconsistent value is an issue that can be
resolved later, reading a value that indicates a lock and handing that value
to code that expects a different type of heap object will almost certainly lead to
a runtime failure.  To avoid this the fine grain lock version of the code will
spin if the value read is a lock, waiting to observe the lock released with an
appropriate pointer to a heap object.

(See [source:rts/STM.c] `stmReadTVar`)

### Writing

Writing to a `TVar` requires that the variable first be in the `TRec`.  If it
is not currently in the `TRec`, a read of the `TVar`'s value is stored in a new
entry (this value will be used to validate and ensure that no updates were made
concurrently to this variable).

In both the fine grain and coarse grain lock versions of the code no
synchronization is needed to perform the write as the value is stored locally
in the `TRec` until commit time.

(See [source:rts/STM.c] `stmWriteTVar`)

### Validation

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

(See [source:rts/STM.c] `validate_and_acquire_ownership` and `check_read_only`)

### Committing

Before committing, each invariant associated with each accessed `TVar` needs to
be checked by running the invariant transaction with its own `TRec`.  The read
set for each invariant is merged into the transaction as those reads must be
included in the consistency check.  The `TRec` is then validated.  If
validation fails, the transaction must start over from the beginning after
releasing all locks.  In the case of the coarse grain lock validation and
commit are in a critical section protected by the global STM lock.  Updates to
`TVar`s proceeds while holding the global lock.

With the fine grain lock version when validation, including any read-only
phase, succeeds, two properties will hold simultaneously that give the desired
atomicity:

-   Validation has witnessed all `TVar`s with their expected value.
-   Locks are held for all of the `TVar`s in the write set.

Commit can proceed to increment each locked `TVar`'s `num_updates` field and
unlock by writing the new value to the `current_value` field.  While these
updates happen one-by-one, any attempt to read from this set will spin while
the lock is held.  Any reads made before the lock was acquired will fail to
validate as the number of updates will change.

(See [source:rts/PrimOps.cmm] `stg_atomically_frame` and [source:rts/STM.c]
`stmCommitTransaction`)

### Aborting

Aborting is simply throwing away changes that are stored in the `TRec`.

(See [source:rts/STM.c] `stmAbortTransaction`)

### Exceptions

An exception in a transaction will only propagate outside of the transaction if
the transaction can be validated.  If validation fails, the whole transaction will 
abort and start again from the beginning.  Nothing special needs to be done
to support the semantics allowing the view *inside* the aborted transaction.

(See [source:rts/Exception.cmm] which calls `stmValidateNestOfTransactions` from
[source:rts/STM.c]).

## Blocking with `retry`

We will now introduce the blocking feature.  To support this we will add a
watch queue to each `TVar` where we can place a pointer to a blocked TSO.
When a transaction commits we will now wake up the TSOs on watch queues for
`TVar`s that are written.

The mechanism for `retry` is similar to exception handling.  In the simple case
of only supporting blocking and not supporting choice, an encountered retry
should validate, and if valid, add the TSO to the watch queue of every accessed
`TVar` (see [source:rts/STM.c] `stmWait` and
`build_watch_queue_entries_for_trec`).  Locks are acquired for all `TVar`s when
validating to control access to the watch queues and prevent missing an update
to a `TVar` before the thread is sleeping.  In particular if validation is
successful the locks are held after the return of `stmWait`, through the return
to the scheduler, after the thread is safely paused (see
[source:rts/HeapStackCheck.cmm] `stg_block_stmwait`), and until `stmWaitUnlock`
is called.  This ensures that no updates to the `TVar`s are made until the TSO
is ready to be woken.  If validation fails, the `TRec` is discarded and the
transaction is started from the beginning. (See [source:rts/PrimOps.cmm]
`stg_retryzh`)

When a transaction is committed, each write that it makes to a `TVar` is
preceded by waking up each TSO in the watch queue.  Eventually these TSOs will
be run, but before restarting the transaction its `TRec` is validated again if
valid then nothing has changed that will allow the transaction to proceed with
a different result.  If invalid, some other transaction has committed and
progress may be possible (note there is the additional case that some other
transaction is merely holding a lock temporarily, causing validation to fail).
The TSO is not removed from the watch queues it is on until the transaction is
aborted (at this point we no longer need the `TRec`) and the abort happens
after the failure to validate on wakeup.  (See [source:rts/STM.c] `stmReWait`
and `stmAbortTransaction`)

## Choice with `orElse`

When `retry#` executes it searches the stack for either a `CATCH_RETRY_FRAME`
or the outer `ATOMICALLY_FRAME` (the boundary between normal execution and the
transaction).  The former is placed on the stack by an `orElse` (see
[source:rts/PrimOps.cmm] `stg_catchRetryzh`) and if executing the first branch
we can partially abort and switch to the second branch, otherwise we propagate
the `retry` further.  In the latter case this `retry` represents a transaction
that should block and the behavior is as above with only `retry`.

How do we support a "partial abort"?  This introduces the need for a nested
transaction.  Our `TRec` will now have a pointer to an outer `TRec` (the
`enclosing_trec` field).  This allows us to isolate effects from the branch of
the `orElse` that we might need to abort.  Let's revisit the features that need
to take this into account.

-   **Reading** -- Reads now search the chain of nested transactions in
    addition to the local `TRec`.  When an entry is found in a parent it is
    copied into the local `TRec`.  Note that there is still only a single
    access to the actual `TVar` through the life of the transaction (until
    validation).

-   **Writing** -- Writes, like reads, now search the parent `TRec`s and the
    write is stored in the local copy.

-   **Retry** -- As described above, we now need to search the stack for a
    `CATCH_RETRY_FRAME` and if found, aborting the nested transaction and
    attempting the alternative or propagating the retry instead of immediately
    working on blocking.

-   **Validation** -- If we are validating in the middle of a running
    transaction we will need to validate the whole nest of transactions.

    (See [source:rts/STM.c] `stmValidateNestOfTransactions` and its uses in
    [source:rts/Exception.cmm] and [source:rts/Schedule.c])

-   **Committing** -- Just as we now have a partial abort, we need a partial
    commit when we finish a branch of an `orElse`.  This commit is done with
    `stmCommitNestedTransaction` which validates just the inner `TRec` and
    merges updates back into its parent.  Note that an update is distinguished
    from a read only entry by value.  This means that if a nested transaction
    performs a write that reverts a value this is a change and must still
    propagate to the parent (see [trac:#7493]).

-   **Aborting** -- There is another subtle issue with how choice and blocking
    interact.  When we block we need to wake up if there is a change to *any*
    accessed `TVar`.  Consider a transaction:

        t = t1 `orElse` t2
    
    If both `t1` and `t2` execute `retry` then even though the effects of `t1`
    are thrown away, it could be that a change to a `TVar` that is only in the
    access set of `t1` will allow the whole transaction to succeed when it is
    woken.

    To solve this problem, when a branch on a nested transaction is aborted the
    access set of the nested transaction is merged as a read set into the
    parent `TRec`.  Specifically if the `TVar` is in *any* `TRec` up the chain
    of nested transactions it must be ignored, otherwise it is entered as a new
    entry (retaining just the read) in the parent `TRec`.

    (See again [trac:#7493] and [source:rts/STM.c] `merge_read_into`)

-   **Exceptions** -- The only change needed here each `CATCH_RETRY_FRAME` on
    the stack represents a nested transaction.  As the stack is searched for a
    handler, at each encountered `CATCH_RETRY_FRAME` the nested transaction is
    aborted.  When the `ATOMICALLY_FRAME` is encountered we then know that
    there is no nested transaction.

    (See [source:rts/Exception.cmm] `stg_raisezh`)

(See [source:rts/PrimOps.cmm] `stg_retryzh` and `stg_catch_retry_frame`)

## Invariants

We will start this section with an overview of some of the details then review
with notes on the changes from the choice case.

### Details

As a transaction is executing it can collect dynamically checked data
invariants.  These invariants are transactions that are never committed, but if
they raise an exception when executed successfully that exception will
propagate out of the atomic frame.

`check#`

:   Primitive operation that adds an invariant (transaction to run) to the
    queue of the current `TRec` by calling `stmAddInvariantToCheck`.

`checkInv :: STM a -> STM ()`

:   A wrapper for `check#` (to give it the `STM` type).

`alwaysSucceeds :: STM a -> STM ()`

:   This is the `check` from the "Transactional memory with data invariants"
    paper.  The action immediately runs, wrapped in a nested transaction so
    that it will never commit but will have an opportunity to raise an
    exception.  If successful, the originally passed action is added to the
    invariant queue. 

`always :: STM Bool -> STM ()`

:   Takes an `STM` action that results in a `Bool` and adds an invariant that 
    throws an exception when the result of the transaction is `False`.

The bookkeeping for invariants is in each `TRec`s `invariants_to_check` queue
and the `StgAtomicallyFrame`s `next_invariant_to_check` field.  Each invariant
is in a `StgAtomicInvariant` structure that includes the `STM` action, the
`TRec` where it was last executed, and a lock.  This is added to the current
`TRec`s queue when `check#` is executed.

When a transaction completes, execution will reach the `stg_atomically_frame`
and the `TRec`s `enclosing_trec` will be `NO_TREC` (a nested transaction would
have a `stg_catch_retry_frame` before the `stg_atomically_frame` to handle
cases of non-empty `enclosing_trec`).  The frame will then check the invariants
by collecting the invariants it needs to check with `stmGetInvariantsToCheck`,
dequeuing each, executing, and when (or if) we get back to the frame, aborting
the invariant action.  If the invariant failed to hold, we would not get here
due to an exception and if it succeeds we do not want its effects.  Once all
the invariants have been checked, the frame will to commit.

Which invariants need to be checked for a given transaction?  Clearly
invariants introduced in the transaction will be checked these are added to the
`TRec`s `invariants_to_check` queue directly when `check#` is executed.  In
addition, once the transaction has finished executing, we can look at each
entry in the write set and search its watch queue for any invariants.

Note that there is a `check` in the `stm` package in `Control.Monad.STM` which matches
the `check` from the [beauty] chapter of "Beautiful code":

    check :: Bool -> STM ()
    check b = if b then return () else retry

It requires no additional runtime support.  If it is a transaction that produces the 
`Bool` argument it will be committed (when `True`) and it is only a one time check, not
an invariant that will be checked at commits.

### Changes from Choice

With the addition of data invariants we have the following changes to the implementation:

-   **Retrying** -- A retry in an invariant indicates that the invariant could not
    proceed and the whole transaction should block.  This special
    case is detected when an `ATOMICALLY_FRAME` is encountered with a nest
    of transactions (i.e. when the `enclosing_trec` field is not `NO_TREC`).
    The invariant is simply aborted and execution proceeds to `stmWait`
    (see [source:rts/PrimOps.cmm] `stg_retryzh`).

-   **Commiting** -- Commit now needs a phase where it runs invariants after
    the code of the transaction has completed but before commit.  The
    implementation recycles the structure already in place for this phase so
    special cases are needed in the `ATOMICALLY_FRAME` that collects invariants
    and works through them one at a time then moves on to committing (see
    [source:rts/PrimOps.cmm] `stg_atomically_frame`).

    To efficiently handle invariants they need to only be checked when a
    relevant data dependency changes.  This means we can associate them with
    the `TRec` of the last commit that needed to check the invariant at the
    cost of serializing invariant handling commits.  This is enforced by the
    lock on each invariant.  If it cannot be acquired the whole transaction
    must start over.

    At commit time, each invariant is locked and the read set for the last
    commited transaction of each invariant is merged into the `TRec`.  
    Validation acuqires lock for all entries in the `TRec` (not just the
    writes).  After validation, each invariant is removed from the
    watch queue of each `TVar` it previously depended on, then the `TRec`
    that was used when executing the invariant code is updated to reflect
    the values from the final execution of the main transaction and each
    `TVar`, being a data depenency of the invariant, has the invariant 
    added to its watch queue.

    (See [source:rts/STM.c] `stmCommitTransaction`, `disconnect_invariant`
    and `connect_invariant_to_trec`)

-   **Exceptions** -- When an exception propagates to the `ATOMICALLY_FRAME`
    there are now two states that it could encounter.  If there is no enclosing
    `TRec` we are not dealing with an exception from an invariant and it
    proceeds as above.  Seeing a nest of transactions indicates that the
    transaction was checking an invariant when it encountered the exception.
    The effect of a failed invariant *is* this exception so nothing special
    needs to be done except to validate and abort both the outer transaction
    and the nested transaction (see [source:rts/Exception.cmm] `stg_raisezh`).

## Other Details

This section describes some details that can be discussed largely in isolation from
the rest of the system.

### Detecting Long Running Transactions

While the type system enforces STM actions to be constrained to STM side effects,
pure computations in Haskell can be non-terminating.  It could be that a transaction
sees inconsistent data that leads to non-termination that would never happen in a 
program that only saw consistent data.  To detect this problem, every time a thread
yields it is validated.  A validation failure causes the transaction to be condemned.

### Transaction State

Each `TRec` has a `state` field that holds the status of the transaction.  It can be
one of the following:

`TREC_ACTIVE`

:   The transaction is actively running.

`TREC_CONDEMNED`

:   The transaction has seen an inconsistency.

`TREC_COMMITTED`

:   The transaction has committed and is in the process of updating `TVar` values.

`TREC_ABORTED`

:   The transaction has aborted and is working to release locks.

`TREC_WAITING`

:   The transaction has hit a `retry` and is waiting to be woken.

If a `TRec` state is `TREC_CONDEMNED` (some inconsistency was seen) validate
does nothing.  When a top-level transaction is aborted in
`stmAbortTransaction`, if the state is `TREC_WAITING` it will remove the watch
queue entries for the `TRec`.  Similarly if a waiting `TRec` is condemned via
an asynchronous exception when a validation failure is observed after a thread 
yield, its watch queue entries are removed.  Finally a `TRec` in the `TREC_WAITING`
state is not condemned by a validation.  In this case the `TRec` is already
waiting for a wake up from a `TVar` that changes and observing an inconsistency
merely indicates that this will happen soon.

In the work of Keir Fraser a transaction state is used for cooperative efforts
of transactions to give lock-free properties for STM systems.  The design of 
GHC's STM is clearly influenced by this work and seems close to some of the
algorithms in Fraser's work.  It does not, however, implement what would be
required to be lock-free or live-lock free (in the fine grain lock code).
For instance, if two transactions `T1` and `T2` are committing at the same time
and `T1` has read `A` and written `B` while `T2` has read `B` and written `A`,
both the transactions can fail to commit.  For example, consider the interleaving:

`T1`           `TVar`              `T2`             Action
-------------  ------------------  ---------------- -------------
`A 0 0`        `A 0`                                `T1` read A
               `B 0`               `B 0 0`          `T2` read B
`B 0 1`                                             `T1` write B 1
                                   `A 0 1`          `T2` write A 1
`A 0 0 0`      `A 0`                                `T1` Validation Part 1 (read A)
               `A T2`                               `T2` Validation (Lock A)
               `B 0`               `B 0 0 0`        `T2` Validation (Read B)
               `B T1`                               `T1` Validation Part 2 (Lock B)

Note: the first and third columns are the local state of the `TRec`s and the
second column is the values of the `TVar` structures.  Each `TRec` entry has the
expected value followed by the new value and a number of updates field when it
is read for validation.

At this point `T1` and `T2` both perform their `read_only_check` and both could
(at least one will) discover that a `TVar` in their read set is now locked.
This leads to both transactions aborting.  The chances of this are narrow but
not impossible (see [trac:#7815]).  Fraser's work avoids this by using the
transaction status and the fact that locks point back to the `TRec` holding the
lock to detect other transactions in a read only check (read phase) and
resolving conflicts so that at least one of the transactions can commit.

A simpler example can also cause both transactions to abort.  Consider two
transactions with the same write set, but the writes entered the `TRec`s
in a different order.  Both transactions could encounter a lock from the
other before they have a chance to release locks and get out of the way.  Having
an ordering on lock could avoid this problem but would add a little more 
complexity.

### GC and ABA

GHC's STM does comparisons for validation by value.  Since these are always
pure computations these values are represented by heap objects and a simple
pointer comparison is sufficient to know if the same value is in place.  This
presents an ABA problem however if the location of some value is recycled it
could appear as though the value has not changed when, in fact, it is a
different value.  This is avoided by making the `expected_value` fields of the
`TRec` entries pointers into the heap followed by the garbage collector.  As
long as a `TRec` is still alive it will keep the original value it read for a
`TVar` alive.

### Management of `TRec`s

The `TRec` structure is built as a list of chunks to give better locality and
amortize the cost of searching and allocating entries.  Additionally `TRec`s
are recycled to aid locality further when a transaction is aborted and started
again.  Both of these details add a little complexity to the implementation
that is abated with some macros such as `FOR_EACH_ENTRY` and `BREAK_FOR_EACH`.

### Tokens and Version Numbers.

When validating a transaction each entry in the `TRec` is checked for
consistency.  Any entry that is an update (in the write set) is locked.  This
locking is a visible effect to the rest of the system and prevents other
committing transactions from progress.  Reads, however, are not going to be
updated.  Instead we check that a read to the value matches our expected value,
then we read a version number (the `num_updates` field) and check again that
the expected value holds.  This gives us a read of `num_updates` that is
consistent with the `TVar` holding the expected value.  Once all the locks for
the write set are acquired we know that only our transaction can have an effect
on the write set.  All that remains is to rule out some change to the read set
while we were still acquiring locks for the writes.  This is done in the read
phase (with `read_only_check`) which checks first if the value matches
the expectation then checks if the version numbers match.  If this holds
for each entry in the read set then there must have existed a moment, while
we held the locks for all the write set, where the read set held all its
values.  Even if some other transaction committed a new value and yet another
transaction committed the expected value back the version number will have been
incremented.

All that remains is managing these version numbers.  When a `TVar` is updated
its version number is incremented before the value is updated with the lock
release.  There is the unlikely case that the finite version numbers wrap around
to an expected value while the transaction is committing (even with a 32-bit version
number this is *highly* unlikely to happen).  This is, however, accounted for
by allocating a batch of tokens to each capability from a global `max_commits`
variable.  Each time a transaction is started it decrements it's batch of
tokens.  By sampling `max_commits` at the beginning of commit and after the
read phase the possibility of an overflow can be detected (when more then
32-bits worth of commits have been allocated out).

(See [source:rts/STM.c] `validate_and_acquire_ownership`, `check_read_only`,
`getToken`, `stmStartTransaction`, and `stmCommitTransaction`)

### Implementation Invariants

Some of the invariants of the implementation:

-   Locks are only acquired in [source:rts/STM.c] and are always released
    before the end of a function call (with the exception of `stmWait` which
    must release locks after the thread is safe).

-   When running a transaction each `TVar` is read exactly once and if it is a
    write, is updated exactly once.

-   Main memory (`TVar`s) always holds consistent values or locks of a
    partially updated commit.  That is a set of reads at any moment from
    `TVar`s will result in consistent data if none of the values are locks.

-   A nest of `TRec`s has a matching nest of `CATCH_RETRY_FRAME`s ending with
    an `ATOMICALLY_FRAME` on the stack.  One exception to this is when checking
    data invariants the invariant's `TRec` is nested under the top level `TRec`
    without a `CATCH_RETRY_FRAME`.

### Fine Grain Locking

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

This arrangement is useful for allowing a transaction that encounters
a locked `TVar` to know which particular transaction is locked (used
in algorithms in from Fraser).  GHC's STM does not, however, use this
information.


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

Fraser, Keir. *Practical lock-freedom*. Diss. PhD thesis, University of Cambridge
Computer Laboratory, 2004.

Jones, Simon Peyton. "Beautiful concurrency." *Beautiful Code: Leading
Programmers Explain How They Think* (2007): 385-406.

Harris, Tim, et al. "Composable memory transactions." *Proceedings of the tenth
ACM SIGPLAN symposium on Principles and practice of parallel programming.* ACM,
2005.

Harris, Tim, James Larus, and Ravi Rajwar. "Transactional memory." *Synthesis
Lectures on Computer Architecture* 5.1 (2010): 1-263.

Harris, Tim, and Simon Peyton Jones. "Transactional memory with data
invariants." *First ACM SIGPLAN Workshop on Languages, Compilers, and Hardware
Support for Transactional Computing (TRANSACT'06), Ottowa.* 2006.
