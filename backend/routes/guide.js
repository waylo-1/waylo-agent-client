// POST /guide      body: { task, steps }  -> { id, url }
// GET  /guide/:id                         -> { task, steps }
// TODO: Day 17 — persist guides in Supabase and generate shareable links.

const express = require('express');
const router = express.Router();

// POST /guide -> store a guide, return its id + shareable url.
router.post('/', async (req, res) => {
  const { task, steps } = req.body || {};
  if (!task || !steps) {
    return res.status(400).json({ error: 'Missing "task" or "steps".' });
  }

  // TODO: Day 17 — insert into Supabase `guides` table and build the share url.
  return res.json({ id: null, url: null });
});

// GET /guide/:id -> fetch a stored guide.
router.get('/:id', async (req, res) => {
  const { id } = req.params;

  // TODO: Day 17 — look up the guide in Supabase by id.
  return res.json({ id, task: null, steps: [] });
});

module.exports = router;
