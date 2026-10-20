---
name: knowledge-graphs-llms-in-action
description: >
  Apply Alessandro Negro's *Knowledge Graphs and LLMs in Action* (Manning MEAP, 2024-25) lens to questions about combining knowledge graphs with LLMs to build Intelligent Advisory Systems (IAS) — grounded, explainable, hallucination-resistant analytics and search. Centers on the property-graph model in Neo4j + Cypher, LLM-driven NER and the three-stage NED pipeline (candidate selection via full-text search → shortest-path detection with hub-node filtering → path-to-text translation → textual path summarization → final disambiguation), Conceptual Search, Structured Knowledge-Based Search, KG-Based Interpretability, New Knowledge Uncovering via co-occurrence relationships, GraphRAG, and the four graph-ML tasks (Node Classification, Link Prediction, Community Detection, Graph Classification) with Node2Vec / GNN embeddings under the homophily assumption. Use when designing a KG-grounded LLM system, scoping text-to-SQL grounding against a semantic model, disambiguating ambiguous metric/dimension mentions, picking GraphRAG vs vector RAG, or making the "semantic-layer-as-knowledge-graph" argument vs flat-metadata competitors. Trigger on requests like "should I use GraphRAG", "knowledge graph grounding for LLM", "how do KGs reduce hallucination", "how do I disambiguate entities with an ontology", "NER vs NED", "schema-first vs schema-less KG", "Neo4j + LLM architecture", "conceptual search vs keyword search", "graph ML for metric recommendation". Skip pure vector-RAG / embedding-search-only questions (no graph in the loop), generic Neo4j tuning, transformer-architecture / LLM-pretraining internals, and BI-visualization design — Negro's frame is the KG+LLM integration loop, not standalone graph DBA work or standalone NLP.
version: 1.0.0
last_updated: 2026-05-18
---

# Knowledge Graphs + LLMs in Action — KGs ground LLMs, LLMs articulate KGs

## Core frame
Neither KGs nor LLMs alone make a robust intelligent system. KGs hold structured, verifiable, typed knowledge but cannot read or talk. LLMs are fluent but hallucinate and have no grounding. Combine them: the LLM reads text, names entities, and writes natural language; the KG (with a domain ontology) validates, disambiguates, explains, and constrains. Negro calls the resulting class of applications **Intelligent Advisory Systems (IAS)**. The integration loop runs both directions — LLMs extract structure from text into the KG (NER, relation extraction), and the KG grounds LLM outputs (NED, GraphRAG, path-based explanation). For AtScale: the semantic layer *is* the domain ontology; metrics, dimensions, hierarchies and joins are nodes and typed edges. KG-grounded text-to-SQL is structurally more robust than embedding-similarity-only retrieval.

## Key concepts
- **Intelligent Advisory System (IAS)** — book's goal architecture: KG + domain ontology + LLM, producing grounded explainable advice
- **Property Graph Model** — nodes, relationships, labels, properties (Neo4j) — relationships are first-class, typed, and carry their own properties
- **Domain Ontology** — typed schema of entities and allowed relationships (SNOMED, UMLS in the book; AtScale semantic model in our context)
- **NER (Named Entity Recognition)** — LLM with prompt-engineered category list + few-shot examples, no domain-specific training required
- **NED (Named Entity Disambiguation)** — map mention to specific ontology entry; three stages: candidate selection → graph reasoning → LLM disambiguation
- **Candidate Selection** — full-text search against KG returns N candidates per mention
- **Shortest Path Detection** — Neo4j GDS shortest paths between candidates of co-occurring mentions, filtered by **Hub Node Filtering** (drop top-K by degree centrality to kill noisy generic paths)
- **Path-to-Text Translation** — LLM converts `(A)-[:REL]->(B)` paths into natural-language sentences
- **Textual Path Summarization** — LLM condenses many translated paths into a single context paragraph fed to the final disambiguation prompt
- **Conceptual Search** — ontology-synonym-aware retrieval (find "pancreatic islets" when searching "Islets of Langerhans")
- **Structured Knowledge-Based Search** — traverse ontology relations (CAUSATIVE_AGENT, FINDING_SITE) to find indirectly related documents
- **KG-Based Interpretability** — ontology paths explain *why* two entities co-occur
- **New Knowledge Uncovering** — frequent co-occurrence + no ontology path = candidate new edge
- **Co-occurrence Relationship** — KG edge created between entities appearing in the same sentence
- **GraphRAG / Retrieval-Augmented Generation** — RAG where the retriever traverses a graph (paths, subgraphs, communities) rather than only ranking text chunks
- **Text-to-Cypher** — LLM generates Cypher from natural language using graph schema injected into the system prompt
- **Four graph-ML tasks** — Node Classification (semi-supervised), Link Prediction (KG completion), Community Detection (unsupervised, Louvain), Graph Classification (whole-graph)
- **Node2Vec / GNNs** — node embeddings from biased random walks or message passing; enable downstream ML on graph data
- **Homophily** — connected nodes share properties; the assumption underwriting most graph ML

## Heuristics
- **Don't ship an LLM into an enterprise data domain without a grounding KG.** Hallucination rate on ambiguous terms (revenue, customer, churn) collapses once a typed ontology constrains output.
- **NER first, NED second — never collapse the two.** Recognition is "what kind of thing is this string"; disambiguation is "which specific entity". Different prompts, different evals.
- **Always run hub-node filtering before path-based reasoning.** Without it, every path goes through "Disease" or "Customer" and you learn nothing. Threshold by degree centrality (book uses top-350 cutoff for SNOMED — tune by graph).
- **Translate paths to text before asking the LLM to reason about them.** LLMs reason far better on natural-language path summaries than on raw Cypher tuples.
- **Inject the graph schema into the system prompt for text-to-Cypher / text-to-SQL.** Don't expect the model to guess label and relationship names.
- **Co-occurrence without an ontology path is a signal, not a fact.** Surface it for human curation; do not auto-write the edge.
- **Pick GraphRAG over vector RAG when answers require multi-hop reasoning, joins, or typed constraints.** Vector RAG retrieves similar text; graph retrieval traverses meaning.
- **Node2Vec is a strong baseline; reach for GNNs only when you have node features that matter and enough labeled data.** High variance on small graphs.
- **A graph-native semantic layer dominates flat-metadata catalogs for LLM grounding.** dbt SL / Cube / Unity Catalog / Cortex / Fabric store metadata; they don't model business semantics as a graph the LLM can traverse.

## When to apply
- Scoping a text-to-SQL or natural-language analytics feature where users say "revenue" and the system must pick among Gross Revenue / Net Revenue / ARR / Revenue-per-Unit
- Designing a GraphRAG pipeline or comparing GraphRAG to vector RAG for an enterprise corpus
- Building an entity-linking pipeline over a domain ontology (SNOMED, UMLS, or AtScale's semantic model)
- Architecting an Intelligent Advisory System: domain ontology + LLM + grounded retrieval + explainable answers
- Justifying why the semantic layer should be graph-native, not YAML-defined or SQL-defined — the "semantic-layer-as-KG" position vs dbt SL, Cube, Unity Catalog, Cortex, Fabric
- Applying graph ML to a semantic model: link prediction for aggregate recommendation, node classification for auto-governance/PII tagging, community detection for subject-area discovery, hub-node analysis for materialization priority
- Explaining LLM-generated SQL by showing the ontology path used to choose joins and filters
- Designing a curation loop where co-occurrence-without-path findings feed human ontology enrichment

## Out of scope
- Pure vector-RAG / embedding-similarity-only retrieval with no graph in the loop (use a vector-DB or RAG reference)
- LLM pretraining, transformer-architecture internals, or fine-tuning recipes (Negro is application-layer)
- Neo4j operational DBA work — clustering, backups, hardware sizing
- BI visualization, dashboard design, or charting libraries
- Generic ML-systems concerns like train/serve skew and drift (use designing-ml-systems)
- Lakehouse table-format wars (Iceberg vs Delta vs Hudi) — use practical-lakehouse-architecture

## Source
*Knowledge Graphs and LLMs in Action*, Alessandro Negro, Manning MEAP 2024-2025. AtScale Reference, 2026.
