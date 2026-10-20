---
name: building-ontologies-with-bfo
description: >
  Apply Robert Arp, Barry Smith, and Andrew Spear's Basic Formal Ontology (BFO,
  ISO 21838) framework to ontology-engineering and semantic-modeling questions.
  Centers on the continuant/occurrent divide, the three kinds of continuant
  (independent, specifically dependent, generically dependent), the realizables
  (role, disposition, function), the process hierarchy, the eight core
  universal-level relations, single inheritance, Aristotelian definitions
  (genus + differentia), the all-some rule, and ontological realism /
  fallibilism / adequatism / perspectivalism. Use when modeling a domain as an
  ontology, deciding which BFO category an entity belongs to, designing a
  semantic layer or knowledge graph with formal grounding, critiquing a
  competitor's "ontology" claim, or aligning AtScale's semantic-layer
  vocabulary with the ISO standard. Trigger on requests like "should this be a
  continuant or occurrent", "how do I model a process in BFO", "is this a role
  or a disposition", "where does a database schema fit in BFO", "what's a GDC",
  "how do I write an Aristotelian definition", "does my is_a hierarchy violate
  single inheritance", "is Palantir's ontology really an ontology", "BFO
  category for metric definitions". Skip pure RDF/OWL syntax questions (this
  is upper-level modeling, not serialization), DOLCE/SUMO/Cyc comparisons
  beyond noting BFO is ISO 21838, conceptual-modeling / ER-diagram questions
  (BFO is realist — concepts are not the target), and SHACL/SPARQL query
  tuning. For lakehouse / catalog architecture questions use
  practical-lakehouse-architecture instead.
version: 1.0.0
last_updated: 2026-05-18
---

# Building Ontologies with BFO — the realist upper-level lens

## Core frame
BFO is a 35-category upper-level ontology, ISO 21838, that splits all of reality into **continuants** (things that persist whole at each moment, no temporal parts) and **occurrents** (things that unfold with temporal parts). Every domain term must land in exactly one BFO leaf via **single inheritance**, with an **Aristotelian definition** (genus + differentia) and relations that obey the **all-some rule**. BFO is **realist** (terms designate universals in reality, not concepts), **fallibilist** (categories are revisable), **adequatist** (every granularity is equally real), and **perspectivalist** (continuant and occurrent views are complementary, not reducible). Before assigning a category, ask the persistence-vs-unfolding question; before asserting a relation, check that ALL instances of the subject bear it to SOME instance of the object.

## Key concepts
- **Continuant** — persists through time, no temporal parts; exists in full at each moment. Three branches below.
- **Independent continuant (IC)** — bearer of qualities, inheres in nothing. Material entity (object, object aggregate, fiat object part) or immaterial entity (site, spatial region, continuant fiat boundary).
- **Specifically dependent continuant (SDC)** — exists only via a specific bearer; cannot migrate. Quality (fully exhibited when present) or realizable entity.
- **Realizable entity** — SDC manifested only through a realizing process. **Role** = externally grounded, optional, lost without physical change (e.g., "PII column", "data steward"). **Disposition** = internally grounded, loss = physical change (e.g., fragility). **Function** = disposition designed/evolved for its purpose (e.g., heart pumps; materialized view accelerates queries).
- **Generically dependent continuant (GDC)** — needs *some* bearer but can migrate across bearers; concretized in SDCs. Information artifacts, schemas, files, sequences, semantic models.
- **Concretization** — GDC ↔ SDC bridge: a GDC (the metric definition) is concretized in an SDC (this YAML's ink/bytes) on a specific IC.
- **Occurrent** — unfolds in time, has temporal parts. Process, history (one-to-one with a material entity), process boundary (instant), temporal region (0D instant or 1D interval), spatiotemporal region (4D).
- **Universal vs particular** — universal = type with instances in reality (the thing an ontology term designates); particular = specific instance. Ontologies represent universals.
- **is_a / single inheritance** — every type has at most one parent; if two parents seem needed, the model is wrong or you need a defined class, not a universal.
- **Aristotelian definition** — "An X is a Y that Zs." Y is the parent (genus), Z is the differentia.
- **All-some rule** — universal-level relation "A R B" means: for ALL instances of A there exists SOME instance of B such that the instance-level R holds. One counterexample falsifies the assertion.
- **Eight core relations** — is_a, continuant-part-of, occurrent-part-of, located-in, adjacent-to, derives-from, preceded-by, has-participant. Plus inheres-in, realized-in, has-history, concretized-in.
- **Four philosophical commitments** — realism (not concepts), fallibilism (revisable), adequatism (no privileged granularity), perspectivalism (continuant + occurrent).

## Heuristics
- **Persist or unfold?** First fork. If you can ask "what is its state at noon today" and get a complete answer, it's a continuant. If "at noon today" gives only a slice, it's an occurrent. Anatomy = continuant view; physiology = occurrent view.
- **Migrates across bearers?** SDC vs GDC test. A metric *definition* migrates from dev to prod (GDC). A metric *value computed at 2pm against this dataset* does not (SDC/quality).
- **Role vs disposition vs function:** lose it without physical change → role. Lose it only via physical change → disposition. Bearer was designed/evolved for it → function. "PII" is a role; "fragile" is a disposition; "pump blood" is a function.
- **Aristotelian template:** write every definition as "An [X] is a [parent BFO leaf] that [differentia]." If you can't, you haven't placed it.
- **All-some sanity check:** before asserting "A R B" at the universal level, find a counterexample-A. If one exists, the assertion is false — weaken to a defined class or pick a different relation.
- **Single-inheritance smell test:** if a term sits under two parents, you have either (a) confused universals with defined classes, (b) confused is_a with part_of/has_role, or (c) a bad cut. Refactor.
- **Information artifact pattern:** schema, model, file, sequence, score = GDC. The bytes on this disk = SDC concretizing it. The disk = IC bearing the SDC.
- **Process modeling:** name the process, list its temporal parts, list its participants (ICs), then locate it in a spatiotemporal region. Process boundaries are instants, not processes.
- **Don't say "ontology" loosely:** an ER diagram, a Power BI semantic model, or a typed property graph is not a BFO ontology. BFO requires universals, formal relations, single inheritance, Aristotelian definitions, and axioms.
- **AtScale mapping shortcuts:** semantic layer = GDC; metric definition = GDC; metric value = quality (SDC); query execution = process; cube/MV = bearer of an acceleration function; PII tag = role; column-null tendency = disposition.

## When to apply
- **"Should this be a continuant or occurrent?"** → apply the persist-or-unfold test; if both views are useful, model both (perspectivalism) and link via has-history.
- **"Where does X fit in BFO?"** → walk the tree: continuant/occurrent → if continuant, IC/SDC/GDC → if IC, material/immaterial → if material, object/aggregate/fiat-part → write the Aristotelian definition.
- **"Is this a role, disposition, or function?"** → run the lose-it test (external circumstance vs physical change vs design intent).
- **"How do I model an information artifact (schema, file, model)?"** → GDC concretized in SDC borne by IC; identity travels with the GDC across bearers.
- **"My type has two parents."** → reject. Pick one is_a; express the other via part_of, has_role, or a defined class.
- **"Is this relation legal?"** → all-some check; if any A-instance lacks a related B-instance, the relation fails at the universal level.
- **"Competitor X says they have an ontology."** → check for ISO 21838 conformance, continuant/occurrent split, single inheritance, formal axioms. Most "ontologies" in BI tooling are typed graphs or dimensional models, not ontologies in the BFO sense.
- **"How do I version a semantic model?"** → GDC identity persists; each version is a new SDC concretization. Lineage = chain of concretizations.

## Out of scope
- **RDF/OWL/Turtle syntax tuning** — BFO is the upper-level lens; serialization choice is downstream. Use an OWL/RDF reference.
- **DOLCE / SUMO / Cyc deep comparisons** — note BFO is the ISO 21838 standard and move on; cross-upper-ontology mapping is its own discipline.
- **Conceptual / ER / UML modeling** — BFO is realist about universals in reality, not concepts in heads or attributes on tables. If the goal is a logical data model, use ER.
- **SPARQL / SHACL / Cypher query tuning** — query layer concerns; BFO informs the schema, not the engine.
- **Lakehouse / catalog architecture** — use the practical-lakehouse-architecture skill; BFO can inform the semantic layer but not the storage tier.
- **Pure taxonomy / controlled-vocabulary work without formal relations** — that's a terminology, not an ontology; don't over-engineer with BFO.

## Source
Building Ontologies with Basic Formal Ontology (Arp, Smith, Spear; MIT Press, 2015); AtScale Reference, 2026.
