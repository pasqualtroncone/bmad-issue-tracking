---
stepsCompleted: [1, 2, 3, 4]
inputDocuments: [prd.md]
---

# Lab PRD - Epic Breakdown

## Overview

Epic and story breakdown for the e2e lab. Story 1.10 exists on purpose: it collides with
story 1.1 under fuzzy title/text search.

## Epic List

- Epic 1: Authentication
- Epic 2: Reporting

## Epic 1: Authentication

Users can authenticate and end their session.

### Story 1.1: Login Form

As a user,
I want to log in with my credentials,
So that I can access my account.

**Acceptance Criteria:**

**Given** a registered user
**When** they submit valid credentials
**Then** they are logged in

### Story 1.2: Logout

As a user,
I want to log out,
So that my session ends.

**Acceptance Criteria:**

**Given** a logged-in user
**When** they click logout
**Then** their session is invalidated

### Story 1.10: Login Form Extended

As a user,
I want "remember me" on the login form,
So that I stay logged in.

**Acceptance Criteria:**

**Given** a user ticking "remember me"
**When** they log in
**Then** the session persists across restarts

## Epic 2: Reporting

Operators get a nightly summary.

### Story 2.1: Report Job

As an operator,
I want a nightly login report,
So that I can spot anomalies.

**Acceptance Criteria:**

**Given** a day of logins
**When** the job runs
**Then** a summary is produced
