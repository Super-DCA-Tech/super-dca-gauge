```mermaid
flowchart TD
    A[Keeper Candidate] -->|approve DCA & call becomeKeeper| B[SuperDCAGauge]
    B -->|requires amount > currentDeposit| B
    B -->|transferFrom candidate deposit| C{Existing keeper?}
    C -->|yes| D[Refund previous keeper]
    C -->|no| E[Skip refund]
    D --> F[Update keeper, keeperDeposit]
    E --> F
    F --> G[beforeSwap hook]
    G --> H{IMsgSender(sender).msgSender()}
    H -->|in isInternalAddress| I[Apply internalFee]
    H -->|= keeper| J[Apply keeperFee]
    H -->|default| K[Apply externalFee]
    I --> L[return override flag to PoolManager]
    J --> L
    K --> L
```
