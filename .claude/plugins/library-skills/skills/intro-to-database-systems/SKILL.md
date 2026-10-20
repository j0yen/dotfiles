---
name: intro-to-database-systems
description: >
  Reference Andy Pavlo's CMU 15-445/645 *Introduction to Database Systems* curriculum
  for relational DBMS internals from disk to query plan — the classical lens for
  understanding how a DBMS actually works, debugging performance, and reasoning
  about correctness. Covers the relational model and SQL, disk-oriented storage
  (slotted pages, log-structured / LSM, index-organized), NSM/DSM/PAX, buffer pool
  management (LRU / CLOCK / LRU-K / ARC, pin counts, dirty flag), columnar
  compression (RLE, bit-packing, bitmap, delta, dictionary), hash tables (linear
  probe, cuckoo, extendible, linear), B+Tree (latch crabbing, prefix/suffix
  compression, bulk insert), filters (Bloom, cuckoo, skip list, trie, inverted,
  vector / HNSW / IVFFlat), join algorithms (nested loop, sort-merge, hash, grace
  hash), the Volcano iterator vs vectorized vs materialization models, sort + hash
  aggregation, the System R bottom-up vs Volcano top-down optimizer, histograms
  (equi-width / equi-depth / end-biased), selectivity estimation, ACID,
  serializability, 2PL (strict / strong strict), OCC + timestamp ordering,
  isolation levels, MVCC + snapshot isolation + write skew, WAL + ARIES recovery
  (analysis / redo / undo, fuzzy checkpoints, CLR, LSN), shared-nothing vs
  shared-disk, consistent / rendezvous hashing, 2PC vs Paxos / Raft, and CAP /
  PACELC. Use when asked how a B+Tree / buffer pool / MVCC / WAL works, why a
  query is slow, ACID vs isolation levels, why a deadlock occurred, the difference
  between row and column stores, or how distributed commit / consensus works.
  Trigger on requests like "how does a B+ tree work", "what's MVCC", "explain the
  buffer pool", "why is my query slow", "ACID vs serializability", "2PC vs Paxos",
  "what's ARIES", "row store vs column store", "hash join vs sort-merge", "what's
  the Halloween problem", "snapshot isolation write skew", "CAP theorem". Skip
  SQL-tuning cookbooks for a specific vendor (Postgres/Oracle/MSSQL internals
  differ — this is the general lens), warehouse pricing / packaging questions,
  semantic-layer architecture (use atscale-technical-reference), and lakehouse
  table-format choices (use practical-lakehouse-architecture).
version: 1.0.0
last_updated: 2026-05-18
---

# Intro to Database Systems (CMU 15-445/645) — the classical DBMS-internals lens

## Core frame

A DBMS is a stack of layers from disk to query plan. **Storage** lays bytes into pages; **buffer pool** decides what lives in memory; **access methods** (heap / B+Tree / LSM) make pages findable; **execution** turns SQL into operators (Volcano / vectorized); **optimizer** picks a plan via rules + cost; **concurrency control** (2PL / OCC / MVCC) preserves serializability; **recovery** (WAL + ARIES) preserves durability after crashes; **distribution** adds partitioning, consensus, and the CAP/PACELC trade. SQL is declarative — the DBMS chooses how. The DBMS almost always manages memory and I/O better than the OS because it knows the query plan.

## Key concepts

### Relational + SQL
- **Codd's three pillars:** structure (relations + attributes), integrity (constraints), manipulation (declarative algebra).
- **Relational algebra:** σ select, π project, ∪ union, ∩ intersect, − difference, × product, ⋈ join. Sets in algebra; SQL uses **bags** (duplicates allowed).
- **SQL features that matter for plans:** window functions (PARTITION BY / OVER), CTEs (incl. RECURSIVE → Turing-complete), lateral joins, nested subqueries (often hard to optimize — de-correlate / flatten).

### Storage
- **Disk-oriented DBMS:** primary store is non-volatile; data must be paged into memory. Never `mmap` for writes.
- **Page layouts:** **slotted page** (header + slot array growing toward tuples) is the dominant tuple-oriented layout. Alternatives: **log-structured** (MemTable → SSTable, LSM-tree, leveled or universal compaction; write amplification) and **index-organized** (table-as-B+Tree).
- **Storage models:** **NSM** (row, OLTP), **DSM** (column, OLAP — fixed-length offsets for reconstruction), **PAX** (row groups with columnar inside — Parquet's ancestor).
- **Columnar compression:** RLE, bit-packing, mostly/patching, bitmap, delta, **dictionary** (most common). Must be lossless, fixed-length, allow **late materialization**.

### Buffer pool + index structures
- **Buffer pool:** frames + **page table** (in-memory) vs **page directory** (on-disk). Each frame tracks **dirty flag** + **pin counter**. Pinned pages cannot evict.
- **Replacement:** **LRU**, **CLOCK** (approximation), **LRU-K** (history of last K accesses), **ARC** (adaptive recency T1 + frequency T2). Watch **sequential flooding** (mitigate with localization, buffer pool bypass, scan sharing, prefetching).
- **Hash tables:** linear probe (state-of-the-art: `absl::flat_hash_map`), cuckoo (multi-table evict-and-rehash), extendible / linear / chained for dynamic resize. Hash function: XXH3.
- **B+Tree:** self-balancing, leaf-only values, sibling pointers (B^link), all leaves at same depth. **Latch crabbing/coupling**: acquire child, release parent if child is *safe* (won't split/merge). **Optimistic protocol**: shared latches down, retry with X on unsafe leaf. Optimizations: prefix compression, suffix truncation, deduplication, pointer swizzling, bulk insert bottom-up, B-ε-Tree.
- **Filters:** **Bloom filter** (probabilistic, no false negatives), counting Bloom, cuckoo filter, **SuRF** (succinct range filter), **skip list** (memtable favorite), **trie / radix tree** (O(k), order-preserving), **inverted index** (Lucene FST, Postgres GIN), **vector index** (IVFFlat, HNSW / FAISS).

### Query execution
- **Plan:** DAG of operators; **pipeline breakers** = hash-build, sort, subquery materialization.
- **Three processing models:** **Volcano / iterator** (`Next()`, pipelined, OLTP-friendly), **materialization** (all at once, small results), **vectorized** (batches + SIMD, OLAP-dominant — DuckDB, ClickHouse).
- **Sort:** in-memory quicksort; **external merge sort** (k-way, B buffers, 1 + log_{B-1}(N/B) passes); **top-N heap** for ORDER BY + LIMIT; double-buffering, key normalization, suffix truncation.
- **Aggregation:** sort-based (sorted output) or hash-based (usually cheaper). External hash aggregate = partition-then-rehash.
- **Joins:** **nested loop** (block NLJ with buffer pool, index NLJ), **sort-merge**, **hash join** (build + probe), **Grace hash join** for spill-to-disk (3·(M+N)). Bloom filter / sideways-information-passing on the probe. Hash join usually wins unless data is already sorted or output must be.
- **Sequential-scan optimizations:** prefetching, buffer pool bypass, parallelization, **zone maps** (per-page min/max for skipping), heap clustering, late materialization, **Halloween problem** (track modified record IDs).

### Query optimization
- **Logical** (algebra → algebra via rules: predicate / projection pushdown, predicate reordering by selectivity, replace cartesian with join, expression rewriting, impossible-predicate folding).
- **Physical** (logical → physical with access methods + costs).
- **Cost model:** CPU, **disk I/O** (dominant), memory, network.
- **Stats:** **histograms** (equi-width, equi-depth, end-biased), **sketches** (Count-Min, HyperLogLog), **sampling**.
- **Selectivity:** SC(A,R) = N_R / V(A,R). **Join cardinality** ≈ (N_R · N_S) / max(V(A,R), V(A,S)). Assumes uniformity + independence + containment — broken by correlated attributes; errors **cascade** through the plan.
- **Search strategies:** **System R bottom-up** = DP, left-deep trees (Postgres, MySQL, DB2). **Volcano / Cascades top-down** = memoization + transformation rules (MSSQL, CockroachDB, Greenplum).

### Concurrency control
- **ACID:** Atomicity, Consistency, Isolation, Durability.
- **Locks** (logical, txn-scoped, deadlock-detected) vs **latches** (physical, short, worker-managed).
- **Conflict serializability** ⊃ serial. Check via dependency-graph acyclicity. Conflicts: WW (lost update), WR (dirty read), RW (unrepeatable read).
- **2PL:** Growing → Shrinking. **Strict 2PL** holds X-locks to commit (avoids cascading aborts). **Strong Strict 2PL** holds all locks to commit (most common in practice).
- **Deadlock:** detect via **waits-for graph** + victim selection; or prevent via **Wait-Die** / **Wound-Wait** with timestamps.
- **Lock granularity:** DB > Table > Page > Tuple > Attribute. **Intention locks:** IS, IX, SIX. Lock escalation when fine-grained count is too high.
- **T/O + OCC:** read / validate / write phases (private workspace). Forward vs backward validation.
- **Phantom problem:** index locking (key-value / gap / key-range / hierarchical) — most common fix.
- **Isolation levels** (ANSI): SERIALIZABLE → REPEATABLE READ → READ COMMITTED → READ UNCOMMITTED. Drop guarantees: phantom, then unrepeatable read, then dirty read.
- **MVCC:** writers don't block readers. **Snapshot Isolation** (first-writer-wins) but allows **write-skew anomaly** (not serializable). Storage: append-only (O2N/N2O), time-travel, delta. **GC**: background vacuuming, cooperative cleaning. Secondary indexes: logical (indirection) vs physical pointers. Most modern systems (Postgres, Oracle, MySQL-InnoDB, SQL Server, CockroachDB) are MVCC.

### Recovery
- **Buffer pool policies:** STEAL / NO-STEAL × FORCE / NO-FORCE. Modern systems use **STEAL + NO-FORCE** (best runtime, hardest recovery → need WAL).
- **WAL rule:** log record flushed before its page; COMMIT not acknowledged until log durable. **Group commit** batches flushes. **CDC** rides the WAL.
- **Logging granularity:** physical, logical, **physiological** (page + slot, most common).
- **ARIES** (IBM, DB2): STEAL + NO-FORCE, **repeat history on redo**, **log undo via CLRs** so redo is idempotent on repeated crashes. Structures: **ATT** (Active Txn Table), **DPT** (Dirty Page Table), **LSN** family (flushedLSN, pageLSN, recLSN, lastLSN, MasterRecord). **Fuzzy checkpoints** allow live txns. Three-pass recovery: **Analysis** (rebuild ATT+DPT) → **Redo** (from min recLSN, even aborted) → **Undo** (reverse-order, write CLRs with undoNextLSN).

### Distributed
- **Architectures:** shared-everything, **shared-nothing** (Snowflake-era classic OLTP scale-out), **shared-disk** (cloud DBMSs, decouples storage from compute), shared-memory.
- **Partitioning:** vertical, **horizontal** (most common), naive. **Consistent hashing** (only 1/n keys move on resize), **rendezvous hashing** (stable per-key score).
- **Atomic commit:** **2PC** (prepare + commit, blocking, fine if same DC + low-failure), **3PC**, **Paxos** / **Multi-Paxos** (non-blocking with majority, 2PC is degenerate Paxos with F=0), **Raft**, **ZAB**, **Viewstamped Replication**.
- **CAP:** during partition, pick **C or A**. **PACELC** extends: if Partition → A vs C; Else → L (latency) vs C.
- **Distributed joins:** replicated × partitioned (free), co-partitioned (free), **broadcast join** (small side), **shuffle join** (worst). Optimize with **semi-join filter** (Bloom).
- **Federation:** multiple DBMSs as one logical system — heterogeneous models, copying overhead, weak global optimization.

## Heuristics

- **The OS is not your friend.** DBMS knows the query plan; OS doesn't. Don't trust mmap, page cache, or fsync semantics for correctness.
- **Disk I/O dominates cost.** Always prefer sequential over random; minimize page touches; columnar + compression + zone maps + late materialization for OLAP.
- **Hash join > sort-merge** unless input is already sorted or output must be.
- **Build hash on the smaller side.** Broadcast the smaller table in distributed joins.
- **Pessimistic (2PL) when conflicts are common; optimistic (OCC/MVCC) when they're rare.** Reads-dominated workloads → MVCC.
- **Snapshot Isolation is not serializable.** Write skew is the canonical counter-example.
- **Cardinality errors cascade.** A 10× selectivity miss at a leaf can become a 1000× miss at the root.
- **Latch crabbing on B+Trees:** start optimistic (S-latches), restart with X only on unsafe leaves.
- **STEAL + NO-FORCE + WAL + ARIES** is the de-facto modern recipe; everything else is a teaching strawman (shadow paging, journals, NO-STEAL+FORCE).
- **For "why is my query slow":** check stats freshness → plan shape (join order, scan vs index) → row estimates vs actuals → buffer-pool hit rate → spill behavior (sort/hash) → I/O pattern.

## When to apply

- Explaining how a B+Tree, buffer pool, MVCC, WAL, or ARIES works.
- Debugging a slow query (estimate-vs-actual, plan shape, spill, hot page).
- Choosing or critiquing an isolation level for an OLTP app (RC vs RR vs SSI).
- Picking row vs column store, hash vs sort-merge join, or batch vs vectorized execution.
- Reasoning about a deadlock (waits-for graph, wait-die vs wound-wait, lock granularity).
- Designing or critiquing a distributed-commit / consensus story (2PC vs Paxos vs Raft, CAP/PACELC).
- Teaching a fundamentals refresher — DBMS internals as taught at CMU 15-445.

## Out of scope

- Vendor-specific tuning playbooks (Postgres VACUUM, Oracle hints, MSSQL wait stats) — this is the general lens, not a per-vendor cookbook.
- Semantic-layer architecture and query routing (use **atscale-technical-reference**).
- Lakehouse / table-format choices like Iceberg vs Delta vs Hudi (use **practical-lakehouse-architecture**).
- ETL/ELT pipelines and data-platform design (use **data-engineering**).
- ML-system operational concerns like drift and feature stores (use **designing-ml-systems**).

## Source

*Introduction to Database Systems*, CMU 15-445/645 (Fall 2025), Andy Pavlo — Carnegie Mellon University. AtScale Reference, 2026-05-18.
