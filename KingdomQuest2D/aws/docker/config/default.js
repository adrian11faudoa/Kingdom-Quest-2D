// =============================================================================
// Kingdom Quest 2D API — config/default.js
// Non-secret configuration values. Secrets come from Secrets Manager.
// =============================================================================

'use strict';

module.exports = {
  api: {
    port:            parseInt(process.env.PORT || '8080'),
    requestTimeout:  30000,   // ms
    bodyLimit:       '2mb',
  },

  cors: {
    // Origins allowed to call this API
    // Prod: lock to your actual domains
    allowedOrigins: (process.env.ALLOWED_ORIGINS || '').split(',').filter(Boolean).concat([
      'http://localhost:3000',
      'http://localhost:6080',
      'http://localhost:8080',
    ]),
  },

  rateLimit: {
    windowMs:   60 * 1000,   // 1 minute window
    maxRequests: 120,         // 2 req/sec burst
    authWindowMs: 15 * 60 * 1000,
    authMaxRequests: 20,
  },

  jwt: {
    // Tokens expire at Cognito level; these are just safety guards
    accessTokenTtl:  3600,    // 1 hour  (must match Cognito setting)
    refreshTokenTtl: 2592000, // 30 days
  },

  saves: {
    maxSlots:         5,
    presignedUrlTtl:  300,    // seconds before upload URL expires
    maxFileSizeBytes: 2 * 1024 * 1024,  // 2 MB
  },

  leaderboard: {
    cacheTtlSeconds: 60,      // Leaderboard Redis cache lifetime
    maxPageSize:     50,
    defaultPageSize: 20,
  },

  analytics: {
    enabled:          true,
    maxEventTypeLen:  100,
    maxPropertiesLen: 4096,
  },

  logging: {
    level: process.env.LOG_LEVEL || (process.env.NODE_ENV === 'production' ? 'info' : 'debug'),
  },

  aws: {
    region:     process.env.AWS_REGION     || 'us-east-1',
    savesBucket: process.env.ASSETS_BUCKET || '',
  },
};
