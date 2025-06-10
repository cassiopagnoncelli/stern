# System Patterns: Stern

## Architecture Overview
Stern follows a layered architecture pattern with clear separation of concerns:

```
Operations Layer (Public API)
    ↓
Entry Pairs Layer (Transaction Logic)
    ↓
Entries Layer (Raw Accounting Records)
    ↓
Books Layer (Chart of Accounts)
    ↓
PostgreSQL (Persistence + Functions)
```

## Core Design Patterns

### 1. Command Pattern (Operations)
- **BaseOperation**: Abstract base class for all financial operations
- **Concrete Operations**: PayBoleto, PayPix, GiveCredit, etc.
- **Bidirectional**: All operations support `do` and `undo` directions
- **Transactional**: Operations wrapped in database transactions with table locking

```ruby
# Pattern Structure
class SomeOperation < BaseOperation
  UID = unique_integer
  def perform(operation_id); end
  def perform_undo; end
end
```

### 2. Double-Entry Enforcement Pattern
- **EntryPair**: Atomic unit ensuring debit + credit balance
- **Immutable Records**: No updates allowed, append-only ledger
- **Validation Layer**: Prevents future timestamps and invalid amounts
- **Database Functions**: PostgreSQL sequences for ID generation

### 3. Configuration-Driven Behavior
- **Chart of Accounts**: YAML-defined books and entry pair definitions
- **Dynamic Method Generation**: EntryPair methods generated from config
- **Book Mapping**: String names mapped to integer IDs for performance

### 4. Factory Pattern (Dynamic Methods)
Entry pairs are created through dynamically generated factory methods:
```ruby
# Generated from chart.yaml
EntryPair.add_balance(uid, gid, amount, ...)
EntryPair.add_credit(uid, gid, amount, ...)
EntryPair.add_boleto_payment(uid, gid, amount, ...)
```

## Key Technical Decisions

### Database Design
- **PostgreSQL-specific**: Leverages sequences, functions, and advanced features
- **Table Locking**: Prevents race conditions during operations
- **Immutable Design**: Records cannot be updated, only created/destroyed
- **Timestamp Validation**: Prevents backdating entries

### Transaction Management
- **Operation-level Transactions**: Each operation runs in a single transaction
- **Table Locking Strategy**: Locks EntryPair and Entry tables during operations
- **ACID Compliance**: Guarantees atomicity, consistency, isolation, durability

### Error Handling
- **Validation Layer**: ActiveModel validations on operations
- **Database Constraints**: Foreign keys and unique constraints
- **Backward Compatibility**: All operations must remain backward compatible

## Component Relationships

### Core Models
- **Book**: Account categories (merchant_balance, boleto, etc.)
- **Entry**: Individual accounting record to a specific book
- **EntryPair**: Paired entries ensuring double-entry balance
- **Operation**: Log of executed operations for audit trail

### Supporting Components
- **Queries**: Balance calculations and reporting
- **Services**: Doctor (consistency checks), SOP (operations parser)
- **Migrations**: Database schema + PostgreSQL functions

## Critical Implementation Paths

### Operation Execution Flow
1. Operation instance created with parameters
2. `call()` method invoked with direction (:do/:undo)
3. Database transaction started with table locks
4. Operation logged to operations table
5. `perform()` method executes business logic
6. Entry pairs created through dynamic methods
7. Transaction committed or rolled back

### Entry Pair Creation Flow
1. Dynamic method called (e.g., `add_balance`)
2. `double_entry_add` creates EntryPair record
3. Two Entry records created (debit + credit)
4. Database constraints ensure consistency
5. Records become immutable

### Undo Operation Flow
1. Operation called with direction: :undo
2. `perform_undo` locates related entry pairs
3. Entry pairs and entries destroyed
4. Operation logged as undo direction

## Performance Considerations
- **PostgreSQL Sequences**: High-performance ID generation
- **Index Strategy**: Optimized for balance queries
- **Table Locking**: Prevents but may limit concurrency
- **Immutable Design**: Enables aggressive caching strategies

## Security & Compliance
- **Append-only Ledger**: Prevents data tampering
- **Audit Trail**: Complete operation history
- **Validation Guards**: Prevents invalid financial operations
- **Transaction Isolation**: Protects against race conditions
