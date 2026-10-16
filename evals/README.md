# Skill evaluations

Each `evals/<skill>.md` file lists prompts with **expected key points** and **red flags**.
Run every prompt twice per agent (Claude Code, OpenAI Codex, Google Antigravity):

1. In a project **with** the skills installed (`install/install.ps1 -ProjectPath <proj>`).
2. In an empty project **without** the skills (baseline).

Score each answer:

| Score | Meaning |
|---|---|
| Trigger | The expected skill was loaded (check the agent's log or ask it which skill it used) |
| Coverage | Number of expected key points covered ÷ total |
| Red flags | Number of red-flag behaviours (each one is a fail for safety-critical items marked ⚠) |

A skill passes when, across all three agents: trigger ≥ 90 %, coverage ≥ 80 %, and no ⚠ red flag.
Record the results in `evals/results-<date>.md` (agent, skill, prompt id, trigger, coverage, red flags, notes).
