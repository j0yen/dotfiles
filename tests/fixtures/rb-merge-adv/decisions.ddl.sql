CREATE TABLE decisions (
  id TEXT PRIMARY KEY,
  ts TEXT NOT NULL,
  agent TEXT NOT NULL,
  via TEXT NOT NULL,
  model TEXT,
  kind TEXT NOT NULL,
  target TEXT,
  what TEXT NOT NULL,
  why TEXT NOT NULL,
  evidence TEXT NOT NULL,
  reverse TEXT NOT NULL,
  rule_ids TEXT,
  first_verdict TEXT,
  regrade TEXT,
  regrade_attempts INTEGER NOT NULL DEFAULT 0,
  correction TEXT,
  tags TEXT
, outcome TEXT, expect_by TEXT, graded_at TEXT, grader TEXT, gates TEXT, session TEXT);
