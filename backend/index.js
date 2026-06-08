// Waylo backend — Express server skeleton.
// Routes:
//   POST /plan        -> Gemini -> JSON step plan      (Day 8)
//   POST /guide       -> store a shareable guide       (Day 17)
//   GET  /guide/:id   -> fetch a shared guide          (Day 17)

require('dotenv').config();

const express = require('express');
const cors = require('cors');

const planRoutes = require('./routes/plan');
const guideRoutes = require('./routes/guide');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());

// Health check.
app.get('/', (req, res) => {
  res.json({ status: 'ok', service: 'waylo-backend' });
});

// Feature routes.
app.use('/plan', planRoutes);
app.use('/guide', guideRoutes);

app.listen(PORT, () => {
  console.log(`Waylo backend listening on port ${PORT}`);
});

module.exports = app;
