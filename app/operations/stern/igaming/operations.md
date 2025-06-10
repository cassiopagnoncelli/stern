# Igaming

## Deposit

**Deposit (Revert)**: customer deposits a currency amount into their account.

**Deposit Fee Customer Pay (Revert)**: deposit fee is paid by the customer.

**Deposit Fee Service Pay (Revert)**: deposit fee is paid by the house.

## Withdraw

**Withdraw Request (Revert)**: customer requests a withdraw, amount is provising from their balance.

**Withdraw Confirm (Revert)**: pending withdraw is marked effectively confirmed.

**Withdraw Fee Customer Pay (Revert)**: withdraw fee is paid by the customer.

**Withdraw Fee Service Pay (Revert)**: withdraw fee is paid by the house.

## Bonus

**Bonus Give (Revert)**: house gives customer a locked bonus.

**Bonus Unlock (Revert)**: customer's locked bonus becomes unlocked, before it can be redeemed.

**Bonus Redeem (Revert)**: customer's unlocked bonus is effectively transfered to customer balance.

## Binary Option Position

**Call Option (Revert)**: customer places a call option (right to buy) on an instrument, reflecting an open position held to be automatically exercised when price goes up.

**Call Expire (Revert)**: call option is expired, thus crediting customer's provisioned amount to the house as profit.

**Call Exercise (Revert)**: call option is exercised, thus returning customer's provisioned amount in excess of a payout paid by the house. Counts towards house P/L.

**Put Option (Revert)**: customer places a put option (right to sell) on an instrument, reflecting an open position held to be automatically exercised when price goes down.

**Put Expire (Revert)**: put option is expired, thus crediting customer's provisioned amount to the house as profit.

**Put Exercise (Revert)**: put option is exercised, thus returning customer's provisioned amount in excess of a payout paid by the house. Counts towards house P/L.
