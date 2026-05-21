# End-to-End Testing Guide

Complete guide for E2E testing of the Reality Engine Docker deployment using Playwright.

## Overview

The E2E test suite validates the full application stack:
- **Qdrant** - Vector database
- **Reality Engine API** - Core backend
- **Visualizer Backend** - Proxy server
- **Visualizer Frontend** - React UI

## Table of Contents

- [Quick Start](#quick-start)
- [Test Framework](#test-framework)
- [Test Structure](#test-structure)
- [Running Tests](#running-tests)
- [Writing Tests](#writing-tests)
- [CI/CD Integration](#cicd-integration)
- [Troubleshooting](#troubleshooting)

## Quick Start

### 1. Install Dependencies

```bash
npm install
npx playwright install
```

### 2. Start Docker Services

```bash
./docker-start.sh
# or
docker-compose up -d
```

### 3. Run E2E Tests

```bash
# Run all tests
npm run test:e2e

# Run with UI mode (recommended for development)
npm run test:e2e:ui

# Run in headed mode (see browser)
npm run test:e2e:headed

# Run with Docker helper script
npm run test:e2e:docker
```

## Test Framework

### Why Playwright?

**Playwright** was chosen for:
- ✅ API + UI testing in one framework
- ✅ Multi-browser support (Chromium, Firefox, WebKit)
- ✅ Excellent Docker integration
- ✅ Fast, reliable, modern
- ✅ Great debugging tools
- ✅ CI/CD ready

### Alternatives Considered

| Framework | Pros | Cons |
|-----------|------|------|
| **Playwright** | All-in-one, modern | Learning curve for complex scenarios |
| Cypress | Great UI testing | Limited API testing |
| Testcontainers | Docker-native | Requires additional UI framework |
| Postman/Newman | Simple API testing | No UI testing |
| k6 | Excellent for load testing | Not designed for functional E2E |

## Test Structure

```
e2e/
├── global-setup.ts           # Setup before all tests
├── global-teardown.ts        # Cleanup after all tests
├── tests/
│   ├── api.spec.ts          # API endpoint tests
│   ├── visualizer-ui.spec.ts # UI component tests
│   └── full-integration.spec.ts # Full workflow tests
├── fixtures/                 # Test data
└── utils/                    # Helper functions
```

### Test Categories

#### 1. API Tests (`api.spec.ts`)
Tests all Reality Engine API endpoints:
- Configuration endpoints
- Vector operations (create, search)
- Sequence management (CRUD)
- Engine processing
- Sampler operations

**Example:**
```typescript
test('should create a new vector', async ({ request }) => {
  const response = await request.post('http://localhost:3000/api/vectors', {
    data: {
      elements: [{ value: 0.5, comparatorType: 'threshold' }],
      isInitial: true
    }
  });
  expect(response.ok()).toBeTruthy();
});
```

#### 2. UI Tests (`visualizer-ui.spec.ts`)
Tests the React visualizer frontend:
- Page load and rendering
- Interactive controls (zoom, pan, keyboard)
- Graph visualization
- Active vector highlighting
- Responsive design
- Auto-refresh functionality

**Example:**
```typescript
test('should display the graph canvas', async ({ page }) => {
  await page.goto('http://localhost:5173');
  const graph = page.locator('[class*="react-flow"]');
  await expect(graph).toBeVisible();
});
```

#### 3. Integration Tests (`full-integration.spec.ts`)
Tests complete user workflows across all services:
- Create sequence → Process vector → View in UI
- Sampler workflow
- Service health checks
- Error handling
- Data persistence

**Example:**
```typescript
test('should create sequence and see in UI', async ({ page, request }) => {
  // Create via API
  const response = await request.post('http://localhost:3000/api/sequences', {
    data: sequenceData
  });

  // Verify in UI
  await page.goto('http://localhost:5173');
  await expect(page.getByText('My Sequence')).toBeVisible();
});
```

## Running Tests

### Basic Commands

```bash
# Run all tests
npm run test:e2e

# Run specific test file
npx playwright test e2e/tests/api.spec.ts

# Run specific test by name
npx playwright test -g "should create a new vector"

# Run in specific browser
npx playwright test --project=chromium
npx playwright test --project=firefox
npx playwright test --project=webkit
```

### Development Mode

```bash
# UI Mode - Interactive test runner (recommended)
npm run test:e2e:ui

# Headed mode - See browser window
npm run test:e2e:headed

# Debug mode - Step through tests
npx playwright test --debug
```

### Docker-Integrated Testing

```bash
# Automatically starts/checks Docker services
npm run test:e2e:docker

# Or use the script directly
./scripts/test-docker-e2e.sh

# Stop services after tests
STOP_SERVICES=true ./scripts/test-docker-e2e.sh
```

### Viewing Results

```bash
# View HTML report
npx playwright show-report e2e-report

# View test results JSON
cat e2e-results.json | jq

# Check for screenshots (on failures)
ls test-results/
```

## Writing Tests

### Test Template

```typescript
import { test, expect } from '@playwright/test';

test.describe('Feature Name', () => {
  test('should do something', async ({ page, request }) => {
    // Arrange
    const testData = { /* ... */ };

    // Act
    const response = await request.post('http://localhost:3000/api/endpoint', {
      data: testData
    });

    // Assert
    expect(response.ok()).toBeTruthy();
    const result = await response.json();
    expect(result).toHaveProperty('id');
  });
});
```

### Best Practices

#### 1. Use Descriptive Test Names
```typescript
// Good
test('should create sequence with initial vector and output vector', ...)

// Bad
test('test1', ...)
```

#### 2. Isolate Tests
```typescript
test.describe('Sequences', () => {
  test.beforeEach(async ({ request }) => {
    // Reset state before each test
    await request.post('http://localhost:3000/api/engine/reset');
  });
});
```

#### 3. Use Fixtures for Test Data
```typescript
// e2e/fixtures/sequences.ts
export const testSequence = {
  name: 'Test Sequence',
  vectors: [/* ... */]
};

// In test
import { testSequence } from '../fixtures/sequences';
test('should create sequence', async ({ request }) => {
  await request.post('/api/sequences', { data: testSequence });
});
```

#### 4. Wait for Elements Properly
```typescript
// Good - wait for specific condition
await expect(page.locator('.graph')).toBeVisible();

// Bad - arbitrary timeout
await page.waitForTimeout(5000);
```

#### 5. Handle Flaky Tests
```typescript
// Retry flaky tests
test.describe.configure({ retries: 2 });

// Or use soft assertions for non-critical checks
await expect.soft(element).toBeVisible();
```

### Common Patterns

#### API Testing
```typescript
test('API endpoint', async ({ request }) => {
  const response = await request.post('http://localhost:3000/api/endpoint', {
    data: { /* ... */ },
    headers: { 'Content-Type': 'application/json' }
  });

  expect(response.ok()).toBeTruthy();
  const data = await response.json();
  expect(data).toMatchObject({ /* ... */ });
});
```

#### UI Testing
```typescript
test('UI interaction', async ({ page }) => {
  await page.goto('http://localhost:5173');

  // Wait for content
  await page.waitForLoadState('networkidle');

  // Interact
  await page.click('button.zoom-in');

  // Assert
  await expect(page.locator('.graph')).toBeVisible();
});
```

#### Full Flow Testing
```typescript
test('complete workflow', async ({ page, request }) => {
  // Backend operation
  const createResp = await request.post('http://localhost:3000/api/sequences', {
    data: sequenceData
  });
  const { id } = await createResp.json();

  // Verify in UI
  await page.goto('http://localhost:5173');
  await expect(page.getByText(sequenceData.name)).toBeVisible();

  // Cleanup
  await request.delete(`http://localhost:3000/api/sequences/${id}`);
});
```

## CI/CD Integration

### GitHub Actions

The project includes a GitHub Actions workflow (`.github/workflows/e2e-tests.yml`) that:
1. Starts Docker services
2. Runs all E2E tests
3. Uploads test reports and screenshots
4. Shows logs on failure
5. Publishes test summary

**Trigger:**
- Push to `main` or `develop`
- Pull requests
- Manual workflow dispatch

### Local CI Simulation

```bash
# Run tests in CI mode
CI=true npm run test:e2e:docker

# This will:
# - Use CI-optimized settings
# - Run headless
# - Stop services after tests
# - Retry failed tests
```

### Custom CI Integration

For other CI systems (GitLab, Jenkins, CircleCI):

```bash
# 1. Start Docker
docker-compose up -d

# 2. Wait for services
sleep 20

# 3. Run tests
npx playwright test

# 4. Cleanup
docker-compose down -v
```

## Configuration

### Playwright Config (`playwright.config.ts`)

Key settings:
- **Timeout**: 60s per test
- **Retries**: 2 in CI, 0 locally
- **Workers**: 1 in CI, auto locally
- **Base URL**: http://localhost:5173
- **Screenshots**: On failure only
- **Videos**: Retain on failure

### Environment Variables

```bash
# CI mode
CI=true npm run test:e2e

# Skip service startup
REUSE_SERVICES=true npm run test:e2e

# Stop services after tests
STOP_SERVICES=true npm run test:e2e:docker
```

## Troubleshooting

### Services Not Starting

```bash
# Check Docker
docker ps

# View logs
docker-compose logs

# Restart services
./docker-restart.sh
```

### Tests Timing Out

Increase timeout in `playwright.config.ts`:
```typescript
timeout: 120 * 1000, // 2 minutes
```

### Flaky Tests

1. Add retries:
```typescript
test.describe.configure({ retries: 2 });
```

2. Wait for specific conditions:
```typescript
await expect(element).toBeVisible({ timeout: 10000 });
```

3. Check service health before tests:
```bash
./docker-status.sh
```

### Port Conflicts

If ports are in use:
```bash
# Find process
lsof -i :3000

# Kill process
kill -9 <PID>

# Or change ports in docker-compose.yml
```

### Browser Installation Issues

```bash
# Reinstall browsers
npx playwright install --with-deps

# Install specific browser
npx playwright install chromium
```

## Advanced Topics

### Parallel Execution

```bash
# Run tests in parallel
npx playwright test --workers=4

# Run specific projects in parallel
npx playwright test --project=chromium --project=firefox
```

### Custom Reporters

Add to `playwright.config.ts`:
```typescript
reporter: [
  ['html'],
  ['json', { outputFile: 'results.json' }],
  ['junit', { outputFile: 'results.xml' }],
  ['allure-playwright']
],
```

### Visual Regression Testing

```typescript
test('visual regression', async ({ page }) => {
  await page.goto('http://localhost:5173');
  await expect(page).toHaveScreenshot('homepage.png');
});
```

### Performance Testing

```typescript
test('page load performance', async ({ page }) => {
  const start = Date.now();
  await page.goto('http://localhost:5173');
  await page.waitForLoadState('networkidle');
  const loadTime = Date.now() - start;

  expect(loadTime).toBeLessThan(3000); // 3 seconds
});
```

## Resources

- [Playwright Documentation](https://playwright.dev/)
- [Best Practices](https://playwright.dev/docs/best-practices)
- [CI/CD Guide](https://playwright.dev/docs/ci)
- [Docker Testing Guide](https://playwright.dev/docs/docker)

## Summary

The E2E test suite provides comprehensive coverage of the Reality Engine deployment:
- ✅ All API endpoints tested
- ✅ UI components and interactions verified
- ✅ Full integration workflows validated
- ✅ Multi-browser support
- ✅ CI/CD ready
- ✅ Docker-native testing

Run tests with: `npm run test:e2e:docker`
