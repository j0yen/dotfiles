---
name: web-ontology-language-owl
description: >
  Apply the W3C OWL 2 (Web Ontology Language) lens — description-logic-based formal
  ontology with classes, object/datatype/annotation properties, individuals, class
  expressions, property restrictions, axioms, the Open World Assumption, and the three
  computational profiles (OWL 2 EL, OWL 2 QL, OWL 2 RL) plus the full OWL 2 DL =
  SROIQ(D). Centers on what reasoners (HermiT, Pellet, FaCT++, Konclude, ELK, Ontop)
  actually do — consistency checking, classification, realization, query answering —
  why OWL beats property graphs for formal guarantees, the Semantic Web stack
  (RDF → RDFS → OWL → SPARQL), and the AtScale-specific argument that OWL 2 QL is
  literally the "semantic layer profile" (OBDA: SPARQL rewritten to SQL, exactly
  what AtScale does). Use when designing a standards-based semantic layer, picking
  an OWL profile, deciding OWL vs property graph vs RDFS, choosing a reasoner,
  formalizing BFO in OWL, or positioning against dbt/Cube/Palantir/data.world.
  Trigger on requests like "OWL DL vs OWL EL vs OWL QL vs OWL RL", "how do I model
  a restriction in OWL", "object property vs datatype property", "should I use OWL
  or RDFS", "which OWL reasoner should I pick", "what is OBDA", "OWL vs Neo4j
  property graph", "what does the Open World Assumption mean for cardinality",
  "how does Ontop rewrite SPARQL to SQL", "formalize BFO in OWL". Skip upper-level
  ontology design questions (use building-ontologies-with-bfo), SPARQL query
  tuning, SHACL validation shapes, RDF triple-store performance, and LLM/KG
  grounding architecture (use knowledge-graphs-llms-in-action).
version: 1.0.0
last_updated: 2026-05-18
---

# Web Ontology Language (OWL 2) — the W3C standard for decidable, reasoner-checkable ontologies

## Core frame
OWL 2 is the W3C standard (Recommendation since 2009, Second Edition 2012) for
expressing ontologies with formally defined description-logic semantics. It sits
above RDF/RDFS in the Semantic Web stack and below SPARQL. The killer property:
because OWL 2 DL corresponds to the decidable description logic SROIQ(D), automated
reasoners (HermiT, Pellet, FaCT++, Konclude, ELK, Ontop) can do four things no
property graph can — verify **consistency**, compute **classification** (the full
subsumption hierarchy), perform **realization** (find the most specific classes
for each individual), and answer queries with **sound and complete** inference.
Three profiles trade expressivity for tractability: **OWL 2 EL** (polynomial-time,
huge classification hierarchies like SNOMED), **OWL 2 QL** (LogSpace query
answering, reducible to SQL — this is the "semantic layer profile"), and
**OWL 2 RL** (forward-chaining rules on RDF). OWL is the formalization language
for BFO (ISO 21838-2) and the standards-based alternative to vendor-specific YAML
or property-graph "ontologies."

## Key concepts
- **OWL 2 DL** — full language, corresponds to SROIQ(D); maximum expressivity that is still decidable.
- **OWL 2 EL** — EL++ profile; polynomial-time reasoning; no `only`, no cardinality, no negation; for large classification hierarchies.
- **OWL 2 QL** — DL-Lite profile; conjunctive query answering in LogSpace; queries rewritten to SQL; the OBDA profile.
- **OWL 2 RL** — DLP profile; forward-chaining rules over RDF; RDFS-toolchain-compatible.
- **Class / Individual / Axiom** — sets of individuals / instances of classes / logical statements asserting facts.
- **Object Property** — relates individuals to individuals; can be `Functional`, `InverseFunctional`, `Transitive`, `Symmetric`, `Asymmetric`, `Reflexive`, `Irreflexive`; `owl:inverseOf`; property chains.
- **Datatype Property** — relates an individual to a literal (XSD-typed value).
- **Annotation Property** — metadata (labels, comments); carries no logical semantics.
- **Class Expression** — complex class built from `owl:intersectionOf`, `owl:unionOf`, `owl:complementOf`, `owl:oneOf`, restrictions.
- **Property Restriction** — `owl:Restriction` with `owl:someValuesFrom` (existential), `owl:allValuesFrom` (universal), `owl:hasValue`, `owl:hasSelf`, `ObjectMinCardinality` / `ObjectMaxCardinality` / `ObjectExactCardinality` (qualified or unqualified).
- **TBox / ABox / RBox** — terminological (schema) / assertional (instance facts) / relational (property axioms).
- **Open World Assumption (OWA)** — absence of information ≠ falsity; cardinality reasoning requires explicit `DifferentIndividuals`; no negation-as-failure.
- **Reasoner** — does consistency / classification / realization / query answering; sound and complete on OWL DL.
- **OBDA (Ontology-Based Data Access)** — OWL 2 QL ontology as virtual schema; SPARQL queries rewritten to SQL by Ontop-style engines.
- **Serializations** — Functional-Style Syntax, RDF/XML, Manchester (Protege), Turtle, JSON-LD.

## Heuristics
- **Pick the profile by workload, not by ambition.** Huge subclass hierarchy → OWL 2 EL. Reasoning over a relational DB → OWL 2 QL. Forward-chaining over RDF → OWL 2 RL. Need full expressivity + can afford reasoner cost → OWL 2 DL. Don't use OWL 2 Full unless you've accepted undecidability.
- **OWL 2 QL is the semantic layer profile.** Its entire design point is ontology-mediated SQL — exactly what AtScale, dbt SL, and Cube do informally. Adopting it isn't a stretch; it's using a W3C standard built for the use case.
- **Cardinality on transitive properties is forbidden in OWL 2 DL** (undecidable). If you need both, redesign the property.
- **Under OWA, two individuals might be the same unless you say otherwise.** Add `DifferentIndividuals` (or UNA assumption) before you trust any cardinality conclusion.
- **Reasoner picks**: HermiT for consistency checking (hypertableau), Konclude for fastest overall, Pellet/Openllet for explanations + SWRL, FaCT++ for fast classification, ELK for OWL 2 EL at SNOMED scale, Ontop for OWL 2 QL → SQL.
- **Hybrid pattern beats pure OWL at runtime.** Author and validate in OWL (formal guarantees), materialize the inferred model into a property graph or in-memory index for fast query planning, fall back to OWL reasoning only for novel inference queries.
- **OWL beats property graphs on standards, reasoning, and federation; loses on edge properties and multi-hop traversal speed.** Choose accordingly — or hybridize.

## When to apply
- Designing a standards-based semantic layer (especially OWL 2 QL for OBDA).
- Picking among OWL 2 DL / EL / QL / RL profiles for a real workload.
- Choosing an OWL reasoner.
- Modeling property restrictions, cardinality, equivalence, disjointness with formal semantics.
- Deciding OWL + RDF vs labeled property graph (or designing a hybrid).
- Formalizing an upper ontology (e.g., BFO) in OWL 2.
- Positioning a semantic product against dbt SL, Cube, Palantir Foundry, data.world.

## Out of scope
- Upper-ontology category design (continuant vs occurrent, role vs disposition) — use **building-ontologies-with-bfo**.
- KG + LLM grounding architecture (GraphRAG, NER/NED, conceptual search) — use **knowledge-graphs-llms-in-action**.
- SPARQL query tuning, triple-store internals, SHACL shape design.
- Property-graph-only modeling (Cypher / GQL / Neo4j tuning).
- AtScale semantic-model authoring mechanics — use **atscale-technical-reference**.

## Source
Web Ontology Language (OWL 2) — Complete Reference, AtScale Reference, 2026-03-24.
W3C OWL 2 Recommendations (Overview, Primer, Profiles, Syntax) and the OWL Reasoners 2023 survey (arXiv 2309.06888).
