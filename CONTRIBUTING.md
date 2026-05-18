# Contributing to OIF Contracts

Thank you for your interest in contributing to OIF Contracts! This document outlines our guidelines, processes, and expectations for contributors.

## Code of Conduct

We are committed to providing a welcoming and inclusive environment for all contributors. By participating in this project, you agree to abide by the following principles:

### Our Standards

- **Be respectful**: Treat all community members with respect and kindness
- **Be inclusive**: Welcome newcomers and encourage diverse perspectives
- **Be constructive**: Provide helpful feedback and engage in productive discussions
- **Be professional**: Maintain a professional tone in all communications
- **Be collaborative**: Work together towards common goals and share knowledge

### Unacceptable Behavior

- Harassment, discrimination, or personal attacks of any kind
- Trolling, insulting comments, or derogatory language
- Publishing private information without permission
- Any conduct that would be inappropriate in a professional setting

## Pull Request Process

### Before You Start

1. **Search existing issues** to ensure your contribution isn't already being worked on
2. **Open an issue** to discuss significant changes before implementing them
3. **Fork the repository** and create a feature branch from `main`

### Pull Request Guidelines

1. **Fill out the PR template** completely
2. **Provide a clear description** of what your PR does and why
3. **Reference related issues** using `Fixes #123` or `Closes #123`
4. **Keep PRs focused** - one feature or fix per PR
5. **Update documentation** if your changes affect public APIs
6. **Ensure all tests pass** and maintain or improve code coverage
7. **Request review** from appropriate maintainers

### PR Review Process

1. **Automated checks** must pass (tests, linting, security scans)
2. **Code review** by at least one maintainer
3. **Security review** for contracts handling funds or critical logic
4. **Final approval** and merge by a maintainer

## Third-Party Integrations

**CRITICAL REQUIREMENT**: All integrations with third-party protocols must follow these strict guidelines:

### Interface and Dependency Management

- **No external library imports**: Do not add third-party contracts as forge dependencies
- **Copy interfaces locally**: All required interfaces must be copied into an `external` folder of the integration. Example: `src/oracles/[oracle-type]/external/` 
- **Minimal dependencies**: Only include the specific interfaces and types needed for integration
- **Self-contained**: Each integration must be fully functional with only the code present in this repository

## OIF Oracle PR Requirements

Oracle implementations have additional strict requirements:

### Non-Upgradeability
- **No proxy patterns**: Oracles must be immutable once deployed
- **No admin functions**: That could change core logic or parameters
- **Final deployment**: Consider the contract final upon deployment

### Ownership Restrictions
- **Minimal ownership**: Only include ownership if absolutely necessary for functionality
- **Justify ownership**: Clearly document why ownership is required
- **Ownership functions**: Must be limited to non-critical operations (e.g., fee collection, not price updates)

### Dependency Management
- **Zero external dependencies**: Follow the third-party integration guidelines above
- **Self-contained oracles**: Must function independently if possible
- **Included interfaces**: Copy all required external interfaces to the repository

### Oracle-Specific Guidelines

1. **Price validation**: Include reasonable bounds checking and staleness protection
2. **Fallback mechanisms**: Consider graceful degradation when external data is unavailable
3. **Gas optimization**: Optimize for gas efficiency as oracles are called frequently
4. **Documentation**: Provide clear documentation on:
   - Data sources and update mechanisms
   - Precision and units used
   - Expected update frequency
   - Failure modes and handling

## Coding Standards

### Solidity Style Guide

- Follow the [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
- Use meaningful variable and function names
- Include comprehensive NatSpec documentation
- Prefer explicit over implicit (e.g., explicit visibility modifiers)

### Security Considerations

- **Reentrancy protection**: Use appropriate guards where needed
- **Input validation**: Validate all external inputs
- **Integer overflow**: Use safe math practices
- **Access control**: Implement proper permission systems
- **External calls**: Handle external call failures gracefully

Thank you for contributing to OIF Contracts! Your efforts help make decentralized infrastructure more robust and accessible.