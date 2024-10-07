1. Anchored or Pegged Stable -> $1.00 
   -> By using Chainlink Price Feed
   -> -> We set a function to exchange ETH and BTC for their dollar equivalent
2. Stability Mechanism -> Algorithmic (Decentralized Stable - No Centralized Entity)
   -> people can only mint the stable with enough collateral (code directly in our protocol)
3. Collateral: Exogenous (Crypto Collaterals), namely we allow to be deposited only either
   -> BTC (actually wBTC)
   -> ETH (actually wETH)

- calculate health factor function
- set health factor if debt is 0
- added a bunch of view function

1. When working with a codebase, always ask - what are our invariants/properties of the system? (for Fuzz Testing)

1. Some proper oracle use
2. Write more tests
3. Smart Contract Audit Preparation