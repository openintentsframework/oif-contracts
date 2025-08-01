## Description

<!-- Provide a clear and concise description of what this PR does -->

## Related Issues

<!-- Link to related issues using "Fixes #123", "Closes #123", or "Relates to #123" -->
- 

## Third-Party Integration Checklist

<!-- Complete this section ONLY if your PR integrates with external protocols -->

**⚠️ CRITICAL: All third-party integrations must follow strict dependency guidelines**

- [ ] **No external library imports** - Confirmed no new dependencies added to `foundry.toml`
- [ ] **Interfaces copied locally** - All required interfaces copied to `src/oracles/[oracle-type]/external/[protocol-name]/`
- [ ] **Proper documentation** - Each copied interface includes source header with:
  - [ ] Protocol name and version
  - [ ] Original source URL
  - [ ] Commit hash and copy date
  - [ ] List of any modifications made
- [ ] **Self-contained** - Integration works with only repository code
- [ ] **Minimal interfaces** - Only copied the specific methods/events needed


## Additional Notes

<!-- Add any additional context, screenshots, or notes for reviewers -->
