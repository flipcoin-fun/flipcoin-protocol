# Contributing to FlipCoin Protocol

Thank you for considering contributing to FlipCoin. This document outlines the process for contributing to the protocol contracts and SDK.

## Prerequisites

- [Foundry](https://getfoundry.sh/) (forge, cast, anvil)
- [Node.js](https://nodejs.org/) >= 18
- [Git](https://git-scm.com/)

## Getting Started

```bash
# Fork and clone the repository
git clone https://github.com/YOUR_USERNAME/flipcoin-protocol.git
cd flipcoin-protocol

# Install Foundry dependencies
forge install

# Build contracts
forge build

# Run tests (370 tests)
forge test

# SDK
cd packages/sdk
npm install
npm test
npm run build
```

## Development Workflow

### 1. Create a Branch

```bash
git checkout -b feat/your-feature   # New feature
git checkout -b fix/your-fix        # Bug fix
git checkout -b docs/your-change    # Documentation
```

### 2. Make Your Changes

- **Solidity**: Follow existing patterns, use Solidity 0.8.30, add NatSpec comments
- **TypeScript SDK**: Match existing code style, add JSDoc where appropriate
- **Tests are mandatory**: Every change must include corresponding tests

### 3. Run Tests

```bash
# Contracts
forge test -vv

# SDK
cd packages/sdk && npm test
```

All tests must pass before submitting a PR.

### 4. Submit a Pull Request

- Use a clear, descriptive title (under 70 characters)
- Include a `## Summary` section explaining what changed and why
- Include a `## Test Plan` section describing how to verify the changes
- Reference any related issues

## Code Standards

### Solidity

- Solidity 0.8.30 with Foundry
- NatSpec documentation on all public/external functions
- Use `custom errors` instead of `require` strings
- Follow checks-effects-interactions pattern
- Use OpenZeppelin contracts where applicable
- All state-changing functions must emit events

### TypeScript (SDK)

- Strict TypeScript (`strict: true`)
- Export all public types
- Include unit tests for all exported functions

## What We Accept

- Bug fixes with regression tests
- Security improvements
- Documentation improvements
- SDK enhancements and new utilities
- Gas optimizations with benchmarks
- New test coverage

## What Requires Discussion First

Open an issue before submitting PRs for:

- New contract features or modifications to existing contracts
- Breaking changes to the SDK API
- Changes to the economic model (fees, collateralization, LMSR parameters)
- New deployment scripts

## Security Vulnerabilities

**Do NOT open a public GitHub issue for security vulnerabilities.**

Please read [SECURITY.md](SECURITY.md) and report vulnerabilities to **security@flipcoin.fun**.

## Code of Conduct

All contributors are expected to follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
