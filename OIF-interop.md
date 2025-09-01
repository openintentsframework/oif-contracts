## Abstract

This specification standardizes intent systems to ensure that components within an intent system can be used composably.

## Motivation

Intents have been proposed as a key element in the broader chain abstraction puzzle. To function effectively, intents must be scalable and expressive. Currently, scalability is limited by the fragmentation of intent execution and validation, while expressivity is constrained by the available settlement structures.

This specification aims to standardize and modularize intent systems, allowing multiple intent systems to reuse and share components. This approach enables intent consumers, producers, or dependents to contribute to scalability by providing open components.

## Specification

The key words “MUST”, “MUST NOT”, “REQUIRED”, “SHALL”, “SHALL NOT”, “SHOULD”, “SHOULD NOT”, “RECOMMENDED”, “MAY”, and “OPTIONAL” in this document are to be interpreted as described in RFC 2119.

### System Design

An intent system comprises of at least three components:
- **Output Settlement**: Records and specifies how outputs are delivered.
- **Validation**: Verifies whether outputs have been delivered through the output settlement.
- **Input Settlement**: Facilitates the collection and release of input tokens.

In this design, data flows from the Output Settlement to the Validation component, and then to the Input Settlement. Consequently, the Output Settlement and Validation components must provide interfaces for subsidiary contracts to read.

The goal is to support **multichain** systems, meaning the design must not restrict the expression of inputs across different chains.

### Output Settlement

Compliant Output Settlement contracts MUST implement the `IOutputSettlement` interface to determine whether a list of payloads is valid.

```solidity
interface IOutputSettlement {
    function hasAttested(
        bytes[] calldata payloads
    ) external view returns (bool);
}
```

The aim is to make the validation layer and output settlement pluggable, meaning the output settlement does not need to know the interface of the validation layer, nor does the validation layer need to conform to a specific standard.

### Validation

Compliant Validation contracts MUST implement the `IOutputValidator` interface to expose valid payloads collected from other chains.

```solidity
interface IOutputValidator {
    /**
     * @notice Check if data has been attested to.
     * @param remoteChainId Chain the data originated from.
     * @param remoteOracle Identifier for the remote attestation.
     * @param remoteApplication Identifier for the application that the attestation originated from.
     * @param dataHash Hash of data.
     * @return boolean Whether the data has been attested to.
     */
    function isProven(uint256 remoteChainId, bytes32 remoteOracle, bytes32 remoteApplication, bytes32 dataHash) external view returns (bool);

    /**
     * @notice Check if a series of data has been attested to.
     * @dev More efficient implementation of requireProven. Does not return a boolean; instead, reverts if false.
     * This function returns true if proofSeries is empty.
     * @param proofSeries remoteOracle, remoteChainId, and dataHash encoded in chunks of 32*4=128 bytes.
     */
    function efficientRequireProven(
        bytes calldata proofSeries
    ) external view;
}
```

#### Validation Payload

The specification does not define how messages are sent between validation contracts, only that Validation layers MUST take valid payloads from `IOutputSettlement` implementations and MUST implement the `IOutputValidator` to make valid payloads available.

While the packaging of payloads is not defined, a RECOMMENDED payload structure is provided below.

```
Common Structure (1 instance)
    SENDER_IDENTIFIER       0       (32 bytes)
    + NUM_PAYLOADS          32      (2 bytes)

Payloads (NUM_PAYLOADS instances)
    + PAYLOAD_LENGTH          M_i+0   (2 bytes)
    + PAYLOAD                 M_i+2   (PAYLOAD_LENGTH bytes)

where M_i = sum_0^(i-1) M_i and M_0 = 34
```

#### (Not) Standardizing Validation Interface

This specification intentionally does not standardize the validation layer interface. Intents used for chain abstraction generally require proof of fulfillment rather than directional messages. As a result, current messaging interfaces are insufficient for this goal in a **multichain** context.

This approach allows each validation interface to be implemented optimally. For example, the following interface assumes it is possible to broadcast a proof that `bytes[] calldata payloads` are valid, without being chain-specific.

```solidity
/// @notice Example validation interface for broadcasting a set of payloads.
function submit(address proofSource, bytes[] calldata payloads) external payable returns (uint256 refund) {
    if (!IAttester(proofSource).hasAttested(payloads)) revert NotAllPayloadsValid();

    return _submit(proofSource, payloads);
}
```

### Input Settlement

The specification does not define which input schemes are used. However, Input Settlements SHALL access proven outputs through either of the validation interfaces – `isProven` or `efficientRequireProven` – allowing Input Settlements to use any validation layer supporting the `IOutputValidator` interface.

### Payload Encoding (Optional)

The specification does not specify an encoding for payloads. Output Settlement systems MAY implement or be inspired by the `FillDescription`:

```
Encoded FillDescription
     SOLVER                          0               (32 bytes)
     + ORDERID                       32              (32 bytes)
     + TIMESTAMP                     64              (4 bytes)
     + TOKEN                         68              (32 bytes)
     + AMOUNT                        100             (32 bytes)
     + RECIPIENT                     132             (32 bytes)
     + REMOTE_CALL_LENGTH            164             (2 bytes)
     + REMOTE_CALL                   166             (LENGTH bytes)
     + FULFILLMENT_CONTEXT_LENGTH    166+RC_LENGTH   (2 bytes)
     + FULFILLMENT_CONTEXT           168+RC_LENGTH   (LENGTH bytes)
```

#### Conflict between Output and Input Settlement

If the Output and Input Settlement implementations use different payload encoding schemes, they will not be composable. Therefore, it is RECOMMENDED to use the `FillDescription` specification whenever possible. However, even in these cases, validation implementations remain composable.

### General Compatibility

`address` variables SHALL be encoded as `bytes32` to be compatible with virtual machines having addresses larger than 20 bytes. This does not affect implementation efficiency.

### Solver Interfaces

This specification does not propose any interface for initiating, solving, or finalizing intents. Secondary interfaces facilitate these processes.

The purpose of this specification is to propose minimal and efficient interfaces for building composable intent protocols and reusing components.

## Security Considerations

The specification allows for the mixing and matching of contracts, which could introduce malicious proofs. Therefore, it is crucial to properly validate, encode, and decode payloads to prevent malicious contracts from entering malicious payloads on behalf of others.
