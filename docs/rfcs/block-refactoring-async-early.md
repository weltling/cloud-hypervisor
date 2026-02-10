# RFC: Cloud Hypervisor Block Crate Refactoring (Async-Early Variant)

**Approach**: General architecture with QCOW2-first implementation. QCOW2 is the most complex format (compression, backing files, COW) and has the biggest performance gap vs QEMU - proving the pattern here ensures other formats (VHDx, VHD) follow easily.

<details open>
<summary><b>Table of Contents</b></summary>

- [Identified Issues](#identified-issues)
  - [Issue 1: Trait Misplacement](#issue-1-trait-misplacement)
  - [Issue 2: Module Organization Chaos](#issue-2-module-organization-chaos)
  - [Issue 3: Naming Inconsistencies](#issue-3-naming-inconsistencies)
  - [Issue 4: Missing Factory Pattern](#issue-4-missing-factory-pattern)
  - [Issue 5: Limited Multi-threading Support](#issue-5-limited-multi-threading-support)
  - [Issue 6: Missing Batch Operation Support](#issue-6-missing-batch-operation-support)
  - [Issue 7: Inconsistent Error Handling](#issue-7-inconsistent-error-handling)
  - [Issue 8: Synchronous QCOW2 Blocks Concurrency](#issue-8-synchronous-qcow2-blocks-concurrency)
- [Context and Rationale](#context-and-rationale)
  - [Current Performance State](#current-performance-state)
  - [Practices from Crosvm](#practices-from-crosvm)
  - [QCOW2 Specification Gaps](#qcow2-specification-gaps)
  - [Async I/O Considerations](#async-io-considerations)
    - [Current Async I/O Architecture (RAW Format)](#current-async-io-architecture-raw-format)
    - [Current Architecture Blocks Async for QCOW2](#current-architecture-blocks-async-for-qcow2)
    - [What Async I/O Enables](#what-async-io-enables)
    - [QCOW2-Specific Async Challenges](#qcow2-specific-async-challenges)
    - [Backing Files Multiply Async Complexity](#backing-files-multiply-async-complexity)
  - [Dependencies Between Improvements](#dependencies-between-improvements)
- [Phased Refactoring Plan](#phased-refactoring-plan)
  - [Cycle 1: QCOW2 Async](#cycle-1-qcow2-async)
    - [Phase 1: QCOW2 Foundation](#phase-1-qcow2-foundation)
      - [Task 1.1: Create New Trait Hierarchy](#task-11-create-new-trait-hierarchy)
      - [Task 1.2: Unified Error Handling (QCOW2 First)](#task-12-unified-error-handling-qcow2-first)
      - [Task 1.3: QcowMetadata with Fine-Grained Locking](#task-13-qcowmetadata-with-fine-grained-locking)
    - [Phase 2: QCOW2 Async Reads](#phase-2-qcow2-async-reads)
      - [Task 2.1: Create QcowAsync](#task-21-create-qcowasync)
      - [Task 2.2: Implement Async Reads](#task-22-implement-async-reads)
      - [Task 2.3: Backing File Support](#task-23-backing-file-support)
      - [Task 2.4: Tests](#task-24-tests)
      - [Task 2.5: Performance Benchmarks](#task-25-performance-benchmarks)
  - [Cycle 2: Expansion](#cycle-2-expansion)
    - [Phase 3: Factory + Other Formats + Reorganization](#phase-3-factory--other-formats--reorganization)
      - [Task 3.1: Factory Pattern](#task-31-factory-pattern)
      - [Task 3.2: Other Formats Adopt New Traits](#task-32-other-formats-adopt-new-traits)
      - [Task 3.3: Reorganize Modules](#task-33-reorganize-modules)
      - [Task 3.4: Apply Naming Conventions](#task-34-apply-naming-conventions)
      - [Task 3.5: Update Imports](#task-35-update-imports)
  - [Cycle 3: Completion](#cycle-3-completion)
    - [Phase 4: Async Writes + Cleanup](#phase-4-async-writes--cleanup)
      - [Task 4.1: Async Writes with COW](#task-41-async-writes-with-cow)
      - [Task 4.2: Compression Handling](#task-42-compression-handling)
      - [Task 4.3: Remove Old Implementations](#task-43-remove-old-implementations)
      - [Task 4.4: Other Formats Follow QCOW2 Pattern](#task-44-other-formats-follow-qcow2-pattern)
      - [Task 4.5: Documentation](#task-45-documentation)
- [Implementation Strategy](#implementation-strategy)
  - [Timeline & Parallelization](#timeline--parallelization)
  - [Testing Approach](#testing-approach)
  - [Risks & Mitigation](#risks--mitigation)
  - [Success Criteria](#success-criteria)

</details>

---

## Identified Issues

### Issue 1: Trait Misplacement
`DiskFile` trait is defined in [async_io.rs](../../block/src/async_io.rs) but
used by all disk types (sync and async). Should be in dedicated `disk_file.rs`
module for clear separation of concerns.

### Issue 2: Module Organization Chaos
Files mix formats with I/O backends (e.g., `fixed_vhd_sync.rs`,
`raw_async.rs`). Inconsistent structure: some formats are files, others
directories. No clear organizational axis.

**Target**: Separate `formats/` (qcow.rs, vhd.rs, vhdx.rs) and `io/`
(io_uring.rs, aio.rs) directories.

### Issue 3: Naming Inconsistencies
`RawFile` vs `RawFileDisk` vs `RawFileAsync`, `QcowFile` vs `QcowSync`,
`FixedVhd` vs `FixedVhdAsync`.

**Target**: Consistent pattern: `{Format}`, `{Format}Sync`, `{Format}Async`.

### Issue 4: Missing Factory Pattern
Callers must know exact type construction details
(`QcowFile::from(RawFile::new(...)?)`, `Vhdx::from_file(...)`).

**Target**: Unified `open_disk_file(path)` with automatic format detection.

### Issue 5: Limited Multi-threading Support
Each virtio-blk device runs in its own thread, and multiple queues within that
device need concurrent access to the disk file. Without `try_clone()` to create
independent file descriptors, all queue operations serialize on a single file
handle, eliminating parallel I/O performance.

**Current state (Feb 2026)**: Data corruption with multiple queues fixed by wrapping QcowFile in `Arc<Mutex<>>` (PR #7661). This ensures correctness but serializes all operations - only one queue can access QCOW2 at a time. Phase 2 of this RFC aims to enable fine-grained locking (separate locks for L1/L2 caches, refcounts, file I/O) so multiple queues can operate in parallel when accessing different clusters.

### Issue 6: Missing Batch Operation Support
Virtio-blk collects multiple I/O requests but synchronous I/O adaptors
(QcowSync, VhdxSync) don't implement `submit_batch_requests()`, forcing
one-by-one processing with excessive syscall overhead.

### Issue 7: Inconsistent Error Handling
Error types scattered across modules: `qcow::Error`, `VhdxError`,
`block::Error`, `DiskFileError`, `AsyncIoError`. No consistent context (file
path, offset), manual conversions between layers.

**Target**: Single `block::Error` with rich context throughout.

### Issue 8: Synchronous QCOW2 Blocks Concurrency

**The Core Problem**: Current `file_read()` and `file_offset_write()` hold `&mut self` during entire operations, including slow disk I/O. As `&mut self` means exclusive borrow in Rust, all other requests wait until the borrow ends.

```
fn file_read(&mut self, ...) {
    // L1/L2 lookup
    let host_offset = self.get_cluster_offset()?;
    
    // Then actual disk I/O, still holding &mut self!
    self.file.read_at(host_offset, buffer)?;  <- BLOCKS HERE
}
```

**Target**: Metadata separation via `ClusterMapping` - lookup returns offset,
caller does I/O without holding lock. This enables concurrent request handling
and is prerequisite for true async I/O.

---

## Context and Rationale

### Current Performance State

Recent benchmarking (Feb 2026) shows:
- Cloud Hypervisor QCOW2: 12.6k IOPS (33.6% of bare metal)
- Cloud Hypervisor RAW: 18.7k IOPS (50.1% of bare metal)  
- QEMU QCOW2: 37.6k IOPS (100.7% of bare metal)

**Primary bottleneck**: fdatasync operations
- Host: 0.75ms average
- Cloud Hypervisor QCOW2: 41.77ms average (56x slower)
- QEMU QCOW2: 17.75ms average (24x slower)

This suggests two optimization areas:
1. fsync path optimization (immediate impact)
2. Async I/O + parallelism (this RFC's focus for long-term gains)

### Practices from Crosvm

Crosvm provides a reference architecture for block device handling, though
Cloud Hypervisor has broader format support (VHD/VHDx, QCOW2 v2+v3 with
zlib/zstd compression) that must be preserved during refactoring.

**Thread Safety by Default**
- Crosvm uses `Mutex` by default for shared state
- Cloud Hypervisor has inconsistent approach: `QcowFile` and `Vhdx` store
  mutable caches (`l2_cache`, `bat_entries`) without synchronization primitives,
  making concurrent access unsafe

**Volatile I/O Support**
- Crosvm has proper volatile memory access traits for guest shared memory
- Cloud Hypervisor doesn't implement this (missing entirely)

**Clone Support for Multi-threading**
- Crosvm has `try_clone()` properly implemented across all disk types
- Cloud Hypervisor: VHD/VHDx have `Clone`, but `QcowFile` doesn't (can't be
  shared across threads)

**Clean Architecture**
- Crosvm has clear trait boundaries, organized modules, factory pattern
- Cloud Hypervisor has traits misplaced, chaotic organization, no factory

### QCOW2 Specification Gaps

The QCOW2 v3 specification defines several features that are currently
unimplemented or only partially supported in Cloud Hypervisor. This section
focuses on features where the refactored architecture would enable cleaner
implementation. Other unimplemented features may exist but are not covered here.

**Incompatible Features That Would Benefit from Refactoring**:
- **Bit 2: External data file** - data clusters stored in separate file
  referenced by header extension. Current implementation: Header field exists
  but never parsed/used. Refactoring benefit - clean format/IO separation makes
  routing I/O to separate data file natural
- **Bit 4: Extended L2 entries** - L2 entries are 128 bits instead of 64 bits,
  enabling subcluster allocation. Not supported. Refactoring benefit -
  thread-safe metadata access enables concurrent subcluster operations

**Compatible Features**:
- **Bit 0: Lazy refcounts** - refcount updates deferred for performance.
  Current implementation: Flag used as marker during refcount rebuilds. Files
  with lazy refcounts trigger full rebuild on open. Refactoring benefit -
  thread-safe refcount cache would enable true lazy update implementation

**Autoclear Features**:
- **Bit 0: Bitmaps** - dirty bitmap extension for incremental backups. Not
  supported. Refactoring benefit - batch operations make bitmap queries
  efficient

**Header Extensions**:
- **0x44415441: External data file** - not implemented, needed for bit 2 above
- **0x23852875: Bitmaps extension** - not implemented, needed for autoclear
  bit 0

**Additional Missing Features**:
- **Encryption**: LUKS encryption - `crypt_method` header field exists but only
  value 0 (no encryption) accepted. Refactoring benefit - format/IO separation
  allows encryption/decryption transforms in I/O layer. Unified error handling
  for decryption failures
- **Snapshots**: Internal snapshots - `nb_snapshots` and `snapshots_offset`
  fields exist but snapshot structures never read/written. Refactoring benefit -
  clean trait boundaries let snapshots be added as separate trait extension
- **Discard/TRIM**: QCOW2 supports marking clusters as unallocated after
  discard. Implementation has `PunchHole` trait but integration with refcount
  updates unclear. Refactoring benefit - unified error handling makes
  multi-step operations (punch hole + update refcounts) more reliable

**How Refactoring Enables These Features**:

1. **Format/IO Separation** (Phase 3): External data files need I/O routed to
   separate file while metadata stays in QCOW2 file - clean separation makes
   this natural

2. **Thread-Safe Metadata** (Phase 2): Extended L2 entries and lazy refcounts
   need concurrent metadata updates - thread-safe metadata access enables this

3. **Batch Operations** (Phase 2): Dirty bitmaps need efficient multi-cluster
   status checks - batch support makes bitmap queries practical

4. **Unified Error Handling** (Phase 1): Complex features like external data
   files fail in intricate ways - error context makes debugging tractable

5. **Clean Trait Boundaries** (Phase 1): Snapshots can be added as separate
   trait extension without polluting core `DiskFile` interface

### Async I/O Considerations

**Current Async I/O Architecture (RAW Format)**

Cloud Hypervisor has a working async I/O implementation for RAW format using io_uring. Understanding this architecture is essential for extending it to QCOW2:

**Submission Path** ([block/src/raw_async.rs](../../block/src/raw_async.rs)):
1. Virtio-blk layer calls `read_vectored()` or `write_vectored()`
2. I/O operation pushed to io_uring submission queue with `user_data` (descriptor index)
3. `submit()` returns immediately - operation executes asynchronously in kernel
4. Multiple operations can be submitted before any complete (parallelism)

**Completion Path** ([virtio-devices/src/block.rs](../../virtio-devices/src/block.rs)):
1. Epoll notifies when completions are ready
2. `process_queue_complete()` polls completion queue via `next_completed_request()`
3. Finds inflight request using `user_data` as key
4. Calls `complete_async()` to finalize request (copy aligned buffers, etc.)
5. Returns descriptor to guest virtqueue

**Key Design Elements**:
- **user_data tracking**: Links completions back to original requests (descriptor chain index)
- **Inflight queue**: VecDeque maintains submitted-but-not-completed requests
- **Out-of-order handling**: Completions may arrive in different order than submissions
- **Event-driven**: io_uring eventfd integrated with epoll for notification
- **Zero-copy**: iovecs point directly to guest memory (when alignment permits)

**Batch Operations**:
- `submit_batch_requests()` collects multiple operations and submits atomically
- Reduces syscall overhead (one `submit()` for many I/O operations)
- Currently only implemented for RAW format

**Current Architecture Blocks Async for QCOW2**

Multiple fundamental issues prevent extending this pattern to QCOW2:

**1. Mutable Self Everywhere**
```rust
fn logical_size(&mut self) -> DiskFileResult<u64>
fn physical_size(&mut self) -> DiskFileResult<u64>
```
`&mut self` means only one operation at a time - impossible to have multiple
concurrent I/O requests.

**2. Tight Coupling of I/O and Format Logic**

Example from QCOW2:
```rust
fn read_cluster(&mut self, cluster: u64) -> Result<Vec<u8>> {
    let compressed_data = self.file.read_at(...)?;  // I/O
    let data = decompress_cluster(compressed_data)?; // Format logic (CPU-bound)
    Ok(data)
}
```
- Can't separate I/O operations from format processing
- CPU-bound work (decompression, metadata parsing) blocks I/O threads
- No way to pipeline operations

**3. No Trait Separation**

All formats forced into same synchronous traits:
- Can't have async variants coexist with sync ones
- No way to express "this format can do async, that one can't"
- DiskFile trait in wrong module (async_io.rs) creates confusion

**4. Thread Safety Issues**

- No synchronization primitives (Mutex/RwLock) used in any format implementations
- Mutable state in `QcowFile`, `Vhdx` not protected for concurrent access
- No clear threading model: unclear which types should be thread-safe

**What Async I/O Enables**

- **Concurrent operations**: Multiple I/O requests in flight simultaneously
- **Better resource utilization**: I/O waits don't block CPU work
- **Scalability**: Handle more requests with same thread count
- **Proper batch processing**: True parallel I/O via io_uring/AIO (as demonstrated by RAW format)
- **Non-blocking format operations**: Can process one cluster while waiting for another

**QCOW2-Specific Async Challenges**

Beyond the general issues listed above, QCOW2 faces unique challenges for async I/O:

1. **Multi-step operations**: Reading a cluster requires:
   - L1 table lookup (metadata read)
   - L2 table lookup (metadata read)  
   - Data cluster read (actual I/O)
   - Possible decompression (CPU-bound)
   
   Each step depends on the previous one, requiring state machine or async/await

2. **Copy-on-write complexity**: Writes may trigger:
   - Refcount lookups/updates
   - New cluster allocation
   - L2 table updates
   - Multiple I/O operations before guest write completes

3. **Cache invalidation**: Async operations on cached metadata need careful ordering to prevent:
   - Reading stale L2 entries
   - Lost updates when multiple async operations modify same metadata
   - Requires `Arc<Mutex<Cache>>` pattern with proper locking

4. **Compression + async**: Can't do both in single thread efficiently:
   - Option 1: Async I/O reads compressed data, blocks thread for decompression
   - Option 2: Offload decompression to thread pool, adds complexity
   - Need strategy for mixing async I/O with CPU-intensive format operations

**Backing Files Multiply Async Complexity**

**Reads without backing files:**
- Max 3 async operations: L1 read -> L2 read -> data read

**Reads with backing files:**
- Overlay: L1 read -> L2 read -> check if allocated
- If unallocated: Backing L1 read -> L2 read -> data read
- Up to 6 async operations per request

**Writes with backing files (COW):**
First write to unallocated cluster is most complex:
1. Overlay L1 -> L2 lookup: cluster unallocated
2. Read original data from backing file (backing L1 -> L2 -> data read)
3. Allocate new cluster in overlay (find free cluster, update refcounts)
4. Merge guest write with backing data (CPU work)
5. Write to overlay (data write)
6. Update overlay L2 entry (metadata write)

Total: **10+ async operations** for first write to a cluster!

Subsequent writes to same cluster are simpler (already allocated in overlay), but the COW path is the bottleneck.

**Additional challenges:**
- State tracking must include which file in chain we're accessing
- Multiple file descriptors involved in io_uring submissions
- Can't hold locks on overlay metadata while waiting for backing file I/O
- COW requires read -> modify -> write across two files
- Each backing file could be different format (QCOW2, RAW)

This is why backing files particularly benefit from Phase 2 (thread-safe metadata with fine-grained locking + ClusterMapping for metadata separation).

### Dependencies Between Improvements

The identified issues and refactoring phases are interconnected. Fixing one enables others:

**Multi-threading Enables Async I/O (Issue 5 to Phase 2)**
- Async I/O requires multiple concurrent operations on the same disk file
- Without thread-safe metadata, `&mut self` methods block concurrency
- Phase 2 adds `Mutex`/`RwLock` to caches AND ClusterMapping for metadata separation

**Trait Organization Blocks Async (Issue 1 to Phase 2)**
- `DiskFile` trait in `async_io.rs` creates circular dependency
- Synchronous formats can't coexist with async variants in same trait
- Phase 1 separates `DiskFile` from `AsyncDiskFile`, enabling Phase 2's async implementations

**Unified Error Handling Critical for Async (Issue 7 to Phase 2)**
- Async operations interleave, making error context tracking harder
- Multi-step operations (metadata update + I/O) need atomic error handling
- Phase 1's unified `block::Error` with context makes Phase 2's async error propagation tractable

**Batch Operations + Async I/O = True Parallelism (Issue 6 + Phase 2)**
- Batch operations alone don't help without async I/O (still blocks on each batch)
- Async I/O alone inefficient without batching (syscall per operation)
- Together: io_uring submits batch, processes other work while kernel handles I/O
- QCOW2 benefits: batch non-compressed cluster reads, async decompress compressed ones

**Factory Pattern Enables Testing (Issue 4 to All Phases)**
- Testing format + I/O backend combinations requires easy instantiation
- Manual construction (`QcowFile::from(RawFile::new(...)?)`) makes tests brittle
- Phase 1's factory pattern simplifies testing all format/backend combinations in Phase 2

**Module Organization Blocks Feature Addition (Issue 2 to QCOW2 Features)**
- Adding QCOW2 external data files requires clear format/I/O separation
- Current mixed organization makes routing I/O to separate files unclear
- Phase 3's `formats/` vs `io/` separation makes external data file feature natural to implement

**Why Async Moves to Phase 2**

Unlike the original RFC where async was Phase 5, this variant moves async foundation to Phase 2 because:

1. **ClusterMapping is the key enabler**: Separating metadata lookup from I/O is the fundamental change - once done, async follows naturally

2. **Thread safety and async are intertwined**: Adding `Mutex`/`RwLock` for thread safety is the same work needed for async - do it once

3. **Early validation of benefit**: Phase 2 async reads prove the architecture before investing in reorganization (Phase 3)

4. **Complex writes can follow**: Phase 2 starts with async reads, write support (COW, compression) can be Phase 4

---

## Phased Refactoring Plan

The plan follows an iterative cycle pattern. Cycle 1 establishes the full pattern with QCOW2 (the most complex format). Subsequent cycles repeat the pattern for other formats and add advanced features.

### Cycle 1: QCOW2 Async

#### Phase 1: QCOW2 Foundation

**Key principle**: Add new code alongside existing code without changing
anything currently used. Nothing breaks because vmm/ keeps using the old APIs.

**Standalone value**: Phase 1 delivers improvements even if later phases are delayed or change direction:
- **Unified errors**: Better debugging and error messages for QCOW2 immediately
- **Clean traits**: New code can use proper `&self` methods, existing code unaffected
- **Fine-grained locking**: Multi-queue QCOW2 benefits immediately (vs current single mutex)
- **No risk**: Additive changes only, existing behavior unchanged

##### Task 1.1: Create New Trait Hierarchy

Create **new file** `block/src/disk_file.rs`:
```rust
// block/src/disk_file.rs - NEW FILE
pub trait DiskFile: DiskGetLen + Send + Debug + AsRawFd {
    fn logical_size(&self) -> io::Result<u64>;
    fn physical_size(&self) -> io::Result<u64>;
    fn try_clone(&self) -> io::Result<Box<dyn DiskFile>>;
    fn topology(&self) -> DiskTopology;
}

pub trait AsyncDiskFile: DiskFile {
    fn create_async_io(&self, ring_depth: u32) -> io::Result<Box<dyn AsyncIo>>;
}
```

**Implementation notes**:
- Old trait: `async_io::DiskFile` (stays unchanged)
- New trait: `disk_file::DiskFile` (different module = no conflict)
- Must add `pub mod disk_file;` to lib.rs to include the file
- **Cycle 1: Only QCOW2 implements new traits** (validates architecture)
- **Cycle 2: RAW, VHDx, VHD adopt new traits** (following proven pattern)

##### Task 1.2: Unified Error Handling (QCOW2 First)

- Create `block/src/error.rs` with unified error type
- Add context: file path, offset, operation name
- **Cycle 1: Migrate QCOW2 errors** (`qcow::Error` → `BlockError`)
- **Cycle 2: Migrate other formats** (VHDx, VHD, RAW errors)
- Implement clean `From<T>` conversions
- Use `thiserror` consistently
- Unified error structure ready for all formats to adopt

##### Task 1.3: QcowMetadata with Fine-Grained Locking

Create shared metadata layer with ClusterMapping (enables both sync and async I/O):

```rust
// block/src/qcow_metadata.rs - NEW FILE

struct ClusterReadMapping {
    host_offset: u64,
    length: u64,
    is_zero: bool,        // Unallocated, return zeros
    is_backing: bool,     // Read from backing file
    backing_depth: u8,    // Which backing file in chain
    is_compressed: bool,  // Needs decompression after read
    compressed_length: u64,
}

struct ClusterWriteMapping {
    host_offset: u64,
    length: u64,
    l1_index: usize,
    l2_index: usize,
    needs_l2_update: bool,
    old_cluster_addr: Option<u64>,  // For refcount update
    needs_cow: bool,
    backing_read_offset: Option<u64>,
}

struct QcowMetadata {
    header: QcowHeader,
    l1_table: Arc<RwLock<Vec<u64>>>,      // RwLock: read-heavy
    l2_cache: Arc<Mutex<LruCache<...>>>,  // Mutex: LRU mutates on read
    refcounts: Arc<Mutex<RefCount>>,
}

impl QcowMetadata {
    fn map_cluster_for_read(&self, offset: u64) -> Result<ClusterReadMapping>;
    fn map_cluster_for_write(&self, offset: u64) -> Result<ClusterWriteMapping>;
    fn commit_write(&self, mapping: ClusterWriteMapping) -> Result<()>;
}
```

**Why in Phase 1**: Fine-grained locking benefits multi-queue QCOW2 immediately, even without async I/O. Current implementation (PR #7661) uses single `Arc<Mutex<QcowFile>>` which serializes all queue operations. `QcowMetadata` with fine-grained locks allows different queues to access different clusters concurrently.

---

#### Phase 2: QCOW2 Async Reads

**Prerequisite**: Phase 1 complete (`QcowMetadata` with locking available).

**Goal**: Create `QcowAsync` that wires io_uring to Phase 1's `QcowMetadata`, enabling async reads for QCOW2.

**Scope - What Phase 2 Delivers:**
- ✅ Async reads from allocated clusters (no compression)
- ✅ Async reads from backing files  
- ✅ Zero-fill for unallocated clusters (no I/O needed)
- ✅ Performance validation (benchmark async reads vs sync)

**Scope - Deferred to Cycle 3 (Phase 4):**
- ❌ Async writes (complex state machine for COW)
- ❌ Compressed cluster handling (needs sync decompression)
- ❌ Full write path with allocation and refcount updates

**Why reads first:**
1. Simpler: Read is lookup → I/O → done (2 steps). Write with COW is 6+ steps.
2. Lower risk: Reads don't modify metadata - no corruption risk if something fails.
3. Validates architecture: If async reads don't show improvement, no point doing complex writes.
4. Common workload: Many VMs are read-heavy (boot, app loading, databases with caching).

**Writes in Phase 2**: Fall back to existing sync path or block. Full async writes come in Cycle 3.

**Cycle 1 Outcome**: Working async QCOW2 reads, validated with benchmarks. Pattern established for other formats.

##### Task 2.1: Create QcowAsync

```rust
// block/src/qcow_async.rs - NEW FILE

struct QcowAsync {
    metadata: Arc<QcowMetadata>,  // From Phase 1
    file: Arc<File>,
    io_uring: IoUring,
}

impl DiskFile for QcowAsync { ... }
impl AsyncDiskFile for QcowAsync { ... }
```

##### Task 2.2: Implement Async Reads

```rust
impl AsyncIo for QcowAsync {
    fn read_vectored(&self, offset: u64, iovecs: &[IoVec], user_data: u64) -> Result<()> {
        // Use Phase 1's QcowMetadata
        let mapping = self.metadata.map_cluster_for_read(offset)?;
        
        if mapping.is_zero {
            return self.complete_with_zeros(user_data, iovecs);
        }
        
        // Submit to io_uring (no lock held)
        self.io_uring.submit_read(mapping.host_offset, iovecs, user_data)
    }
}
```

##### Task 2.3: Backing File Support

```rust
if mapping.is_backing {
    let backing_fd = self.backing_file_fd(mapping.backing_depth)?;
    self.io_uring.submit_read_to_fd(backing_fd, mapping.host_offset, iovecs, user_data)
}
```

##### Task 2.4: Tests

- Async read from allocated cluster
- Async read from unallocated (zero) cluster
- Async read from backing file
- Concurrent reads from multiple queues

##### Task 2.5: Performance Benchmarks

- Before/after comparisons for async reads
- Random I/O patterns (where async shines)
- Multiple queue scenarios

**Deferred to Cycle 3**:
- Async writes with COW
- Compressed cluster handling
- VHDx async support

---

### Cycle 2: Expansion

#### Phase 3: Factory + Other Formats + Reorganization

**Goal**: Add factory pattern (now needed for multiple formats), have RAW, VHDx, VHD adopt the new traits, and reorganize code structure.

##### Task 3.1: Factory Pattern

Create **new file** `block/src/factory.rs`:
```rust
// block/src/factory.rs - NEW FILE
pub fn open_disk_file(params: DiskFileParams) -> Result<Box<dyn DiskFile>> {
    // Read file header to detect format
    // Return appropriate format wrapped in new trait
}
```

##### Task 3.2: Other Formats Adopt New Traits

Each format implements the new `disk_file::DiskFile` trait (from Task 1.1), migrating from the old `async_io::DiskFile`:

**RAW Format** (`raw_async.rs`, `raw_sync.rs`, `raw_async_aio.rs`):
```rust
// Implements both sync and async traits
impl disk_file::DiskFile for RawFileDisk { ... }
impl disk_file::AsyncDiskFile for RawFileDisk {
    fn create_async_io(&self, ring_depth: u32) -> io::Result<Box<dyn AsyncIo>> {
        // Existing io_uring code extracted to shared io/io_uring.rs
        Ok(Box::new(IoUringAsync::new(self.file.as_raw_fd(), ring_depth)?))
    }
}
```
- Already has io_uring support - becomes reference implementation
- io_uring code extracted to `io/io_uring.rs` for sharing with QCOW2

**VHDx Format** (`vhdx_sync.rs`):
```rust
impl disk_file::DiskFile for VhdxDiskSync {
    fn logical_size(&self) -> io::Result<u64> {
        Ok(self.vhdx_file.virtual_disk_size())  // &self not &mut self
    }
    fn physical_size(&self) -> io::Result<u64> { ... }
    fn try_clone(&self) -> io::Result<Box<dyn DiskFile>> { ... }
    fn topology(&self) -> DiskTopology { ... }
}
// AsyncDiskFile NOT implemented yet - comes in Phase 4
```
- Currently sync-only (uses `AsyncAdaptor` shim)
- New trait uses `&self` instead of `&mut self` - requires internal mutability pattern
- VhdxAsync deferred to Phase 4 (following QCOW2 pattern)

**VHD Format** (`fixed_vhd_sync.rs`, `fixed_vhd_async.rs`):
```rust
impl disk_file::DiskFile for FixedVhdDiskSync { ... }
impl disk_file::DiskFile for FixedVhdDiskAsync { ... }
// Note: FixedVhdDiskAsync already uses io_uring
```
- Fixed-size format, simpler than VHDx
- `FixedVhdDiskAsync` already exists with io_uring - can implement `AsyncDiskFile`

**Migration Pattern** (for all formats):
1. Add `impl disk_file::DiskFile for XxxDisk { ... }` alongside existing impl
2. Convert `&mut self` methods to `&self` (add interior mutability where needed)
3. Use new `BlockError` type from Task 1.2
4. Keep old `async_io::DiskFile` impl for backward compatibility (removed in Phase 4)

**Factory Integration**:
```rust
// factory.rs
pub fn open_disk_file(params: DiskFileParams) -> Result<Box<dyn DiskFile>> {
    let header = read_file_header(&params.path)?;
    match detect_format(&header) {
        Format::Raw => Ok(Box::new(RawFileDisk::new(file)?)),
        Format::Qcow2 => Ok(Box::new(QcowDiskSync::new(file)?)),
        Format::Vhdx => Ok(Box::new(VhdxDiskSync::new(file)?)),
        Format::Vhd => Ok(Box::new(FixedVhdDiskSync::new(file)?)),
    }
}
```

##### Task 3.3: Reorganize Modules

```
block/src/
├── disk_file.rs
├── factory.rs
├── formats/
│   ├── raw.rs        (from raw.rs)
│   ├── qcow.rs       (from qcow/mod.rs)
│   ├── vhd.rs        (from fixed_vhd*.rs)
│   └── vhdx.rs       (from vhdx/mod.rs)
└── io/
    ├── io_uring.rs   (extracted from raw_async.rs) - shared by all formats
    └── aio.rs        (from raw_async_aio.rs)
```

**Note on RAW**: RAW format's io_uring code becomes shared infrastructure in `io/io_uring.rs`. QcowAsync and other formats use this same io_uring layer.

##### Task 3.4: Apply Naming Conventions

- Rename types systematically
- Update all references
- Maintain compatibility shims

##### Task 3.5: Update Imports

- Re-export from new locations
- Update vmm/ usage
- Update documentation

**Cycle 2 Outcome**: All formats use unified trait hierarchy. Factory pattern provides clean format detection. Code reorganized into logical structure with shared io_uring infrastructure. Ready for non-QCOW2 async support.

---

### Cycle 3: Completion

#### Phase 4: Async Writes + Cleanup

**Goal**: Complete async QCOW2 support (writes, compression) and apply pattern to other formats.

**Scope - What Phase 4 Delivers:**
- ✅ Async writes to already-allocated clusters
- ✅ Async writes with COW (state machine for backing file operations)
- ✅ Compressed cluster reads (with sync decompression)
- ✅ VHDx async support following QCOW2 pattern
- ✅ Cleanup of old code paths
- ✅ Documentation

##### Task 4.1: Async Writes with COW

Implement the complex write path:

```rust
// Write to unallocated cluster with backing file
fn async_write_cow(&mut self, offset: u64, data: &[u8], user_data: u64) -> Result<()> {
    let mapping = self.map_cluster_for_write(offset)?;
    
    if mapping.needs_cow {
        // State machine: read backing -> write overlay -> commit
        self.start_cow_operation(mapping, data, user_data)
    } else {
        // Simple write
        self.io_uring.submit_write(mapping.host_offset, data, user_data)
    }
}
```

##### Task 4.2: Compression Handling

QCOW2 compression creates CPU-bound work in async path. Two strategies:

**Option A: Inline decompression**
- Read compressed data asynchronously
- Decompress synchronously when completion arrives
- Simple but blocks thread during decompression

**Option B: Decompression pool**
- Read compressed data asynchronously  
- Submit to rayon thread pool for decompression
- Another async completion when decompression finishes
- Complex but maintains thread responsiveness

Start with Option A, consider Option B if profiling shows compression as bottleneck.

##### Task 4.3: Remove Old Implementations

- Delete old trait definitions (`async_io::DiskFile`)
- Clean up compatibility shims from Phase 3
- Remove unused code paths

##### Task 4.4: Other Formats Follow QCOW2 Pattern

Apply the proven metadata separation pattern to other formats:

```
RAW   (already):     No metadata     → direct offset   → RawFileAsync (reference)
QCOW2 (Phase 2):     QcowMetadata    → ClusterMapping  → QcowAsync
VHDx  (Phase 4):     VhdxMetadata    → BlockMapping    → VhdxAsync
VHD   (Phase 4):     (simpler, may not need full pattern)
```

- **RAW**: Already async, serves as reference. io_uring code extracted to shared `io/io_uring.rs`
- **VHDx**: Apply same pattern, simpler than QCOW2 (no compression, no backing files)
- **VHD**: Fixed-size format with minimal metadata, evaluate if full pattern needed

##### Task 4.5: Documentation

- Module-level docs with examples
- Trait documentation
- Architecture decision records
- Internal API guide for future contributors

---

## Implementation Strategy

### Timeline & Parallelization

| Cycle | Phase | Duration | QCOW2 Reads | QCOW2 Writes | Focus |
|-------|-------|----------|-------------|--------------|-------|
| 1 | 1 | 2-3 weeks | sync | sync | Foundation (traits, errors, QcowMetadata) |
| 1 | 2 | 2-3 weeks | **async** | sync fallback | Wire io_uring to QcowMetadata |
| 2 | 3 | 2-3 weeks | async | sync fallback | Factory + other formats + reorganization |
| 3 | 4 | 2-3 weeks | async | **async** | Async writes with COW state machine |

**Total**: 8-12 weeks (sequential)

**Write fallback in Phases 1-3**: Writes go through `QcowMetadata.write_sync()` which uses existing COW logic. From virtio-block's perspective, writes complete normally - just synchronously. The completion is pushed to the queue immediately after the sync write finishes.

```rust
// Phase 2-3: QcowAsync write path
fn write_vectored(&mut self, offset: i64, iovecs: &[iovec], user_data: u64) -> Result<()> {
    // Use existing sync write path (full COW handling)
    self.metadata.write_sync(offset, iovecs)?;
    // Signal completion immediately
    self.completion_list.push_back((user_data, 0));
    self.eventfd.write(1)?;
    Ok(())
}
```

**Cycle structure**:
- **Cycle 1 (Phases 1-2)**: QCOW2-only. Foundation + async reads. Writes use sync fallback.
- **Cycle 2 (Phase 3)**: Expansion. Factory pattern introduced. Writes still sync fallback.
- **Cycle 3 (Phase 4)**: Completion. Async writes with COW state machine.

**QCOW2-first principle**: Cycle 1 focuses entirely on QCOW2. Phase 1 includes `QcowMetadata` with fine-grained locking, which benefits multi-queue immediately. Phase 2 wires io_uring to validate async. Existing code for all formats remains untouched until Cycle 2.

**Key difference from original RFC**: Async validation happens in Phase 2 (Cycle 1), before reorganization investment. If Phase 2 doesn't show benefit, can stop without wasted reorganization effort.

### Testing Approach

- **Unit**: Each format/I/O backend independently
- **Integration**: All format + I/O backend combinations, backing file chains
- **Async-specific**: Concurrent reads, out-of-order completion handling
- **Performance**: Sequential/random I/O, multi-queue scenarios
- **Regression**: Existing test suite + real VM workloads

### Risks & Mitigation

**High-risk areas**:
1. Phase 2 ClusterMapping design - mitigation: start with read-only, validate before writes
2. Phase 3 reorganization - mitigation: staged rollout, comprehensive test coverage
3. Phase 4 async writes complexity - mitigation: thorough state machine testing

**Safety measures**: Feature flags for new code paths, fallback mechanisms,
gradual deployment, CI performance monitoring

### Success Criteria

- **Cycle 1 validation**: Async reads show measurable improvement for random I/O workloads
- **Architecture**: Clear module boundaries, consistent naming, comprehensive documentation
- **Performance**: Random I/O approaches RAW format performance
- **Velocity**: Add new format <2 weeks, new I/O backend <1 week
