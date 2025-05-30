# Project Brief: Stern

## Project Overview
Stern is a double-entry ledger Rails engine designed to be the source of truth for all accounting entries in financial applications. It provides scalable, atomic financial operations with built-in consistency guarantees.

## Core Requirements
- **Double-entry accounting**: Every transaction must balance (inputs = outputs)
- **Operations abstraction**: Users interact with high-level operations, not raw entries
- **Atomic transactions**: Entry pairs are ACID-compliant
- **Chart of accounts**: Configurable books and entry pair definitions
- **PostgreSQL backend**: Leverages PL/pgSQL functions for performance
- **Rails engine**: Mountable into existing Rails applications

## Primary Goals
1. Provide reliable financial transaction processing
2. Maintain accounting consistency and auditability
3. Support complex financial operations (payments, fees, settlements, refunds)
4. Enable real-time balance queries and reporting
5. Scale to handle high-volume financial transactions

## Key Constraints
- Commercial license requiring written authorization
- PostgreSQL dependency for advanced database features
- Rails 8.0+ requirement
- Must handle timezone-aware datetime operations
- Requires careful migration management for database functions

## Success Criteria
- Zero data inconsistency in double-entry accounting
- Support for all common payment operations (boleto, PIX, credit card)
- Real-time balance and reporting capabilities
- Production-ready performance for financial workloads
- Clean API for operations without exposing internal entry mechanics

## Project Scope
**In Scope:**
- Core ledger functionality (entries, entry pairs, operations)
- Payment operation implementations
- Balance and reporting queries
- Database migration and setup tools
- RSpec testing suite

**Out of Scope:**
- User interface beyond basic Rails views
- Payment gateway integrations (handled by parent applications)
- Real-time notifications or webhooks
- Multi-currency support (single currency focus)
