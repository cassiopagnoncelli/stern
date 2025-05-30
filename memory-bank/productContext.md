# Product Context: Stern

## Why This Project Exists
Financial applications require bulletproof accounting systems to handle money movements. Traditional approaches often:
- Lack proper double-entry guarantees
- Mix business logic with accounting mechanics
- Don't scale for high-volume transactions
- Create opportunities for data inconsistency

Stern solves these problems by providing a dedicated, battle-tested ledger engine that financial applications can embed.

## Problems It Solves
1. **Accounting Integrity**: Prevents financial data corruption through enforced double-entry rules
2. **Operation Complexity**: Abstracts complex multi-step financial operations into simple API calls
3. **Performance**: Uses PostgreSQL functions for high-performance financial calculations
4. **Auditability**: Maintains complete transaction history with temporal consistency
5. **Scalability**: Designed for high-volume financial transaction processing

## How It Works
### Core Architecture
- **Entries**: Individual accounting records to specific books
- **Entry Pairs**: Atomic double-entry transactions (debit + credit)
- **Operations**: High-level business operations composed of entry pairs
- **Books**: Account categories defined in chart of accounts
- **Queries**: Real-time balance and reporting capabilities

### User Workflow
1. Configure chart of accounts (books + entry pair definitions)
2. Define custom operations for business-specific transactions
3. Execute operations through clean Ruby API
4. Query balances and generate reports in real-time

### Example Operation Flow
**Credit Card Payment Processing:**
```
PayCreditCard.call(amount: 1000, merchant_id: 123)
├── add_credit_card_captured (cash in)
├── add_credit_card_fee (transaction fee)
├── add_credit_card_internal_fee (processing fees)
├── add_merchant_balance_withholding (escrow funds)
└── schedule: add_merchant_balance (release funds later)
```

## Target Users
- **Fintech developers** building payment platforms
- **E-commerce platforms** needing robust financial tracking
- **Financial institutions** requiring audit-compliant ledgers
- **Marketplace operators** managing complex money flows

## User Experience Goals
- **Simple API**: Operations should be one-line method calls
- **Zero Manual Entries**: Users never touch raw entries or entry pairs
- **Real-time Queries**: Instant balance and report generation
- **Configuration-driven**: Chart of accounts defines all behavior
- **Rails Integration**: Seamless embedding in existing Rails apps

## Business Value
- **Risk Reduction**: Eliminates financial data corruption risks
- **Compliance**: Built-in audit trails and consistency checks
- **Developer Velocity**: Pre-built operations for common financial scenarios
- **Operational Confidence**: Battle-tested double-entry accounting principles
- **Scalability**: Handles growth from startup to enterprise volumes
