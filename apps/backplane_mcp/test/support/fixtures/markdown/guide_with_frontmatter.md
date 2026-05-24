---
title: Deployment Guide
author: Team
version: 2.1
tags:
  - deployment
  - production
---

# Deployment Guide

This guide covers deploying the application to production.

## Prerequisites

- Elixir 1.18+
- PostgreSQL 16+
- Docker (optional)

## Steps

1. Build the release: `mix release`
2. Run migrations: `bin/myapp eval "MyApp.Release.migrate"`
3. Start the server: `bin/myapp start`
