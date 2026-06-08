// POST /plan
// TODO: Day 8 — call Gemini 1.5 Flash with the plan-generation prompt and
// return { task, app, steps: [{ index, instruction, findDescription }] }.

const express = require('express');
const router = express.Router();

// POST /plan  body: { task: string }  -> { steps: Step[] }
router.post('/', async (req, res) => {
  const { task } = req.body || {};
  if (!task) {
    return res.status(400).json({ error: 'Missing "task" in request body.' });
  }

  // TODO: Day 8 — build the SYSTEM/USER prompt, call Gemini via GEMINI_API_KEY,
  // parse the JSON response, and return it. For now return an empty plan stub.
  return res.json({ task, app: null, steps: [] });
});

module.exports = router;
