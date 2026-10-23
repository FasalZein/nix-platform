---
name: roster-fixture-worker
description: Hermetic spawnable agent used to inspect the final provider request.
model: xai/grok-4.3
mode: background
session-mode: fork
async: false
auto-exit: true
idle-timeout: 60
context-warn-threshold: 80%
visible-to: root
enabled: true
---

Observe the roster fixture only.
