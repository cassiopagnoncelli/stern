# Active Context: Stern

## Current Work Focus
**Memory Bank Initialization** - Establishing comprehensive documentation of the Stern double-entry ledger project to enable effective future development and maintenance.

## Recent Changes
- Created initial memory bank structure with core documentation files
- Analyzed project architecture and established understanding of:
  - Double-entry ledger design patterns
  - Operations-based API architecture
  - PostgreSQL-specific implementation details
  - Rails engine integration patterns

## Next Steps
1. **Complete Memory Bank Setup**: Finish creating progress.md to establish current project status
2. **Address Book ID Mapping**: Priority architectural change to use book names instead of IDs
3. **Finalize ScheduledOperation**: Complete the scheduled operation functionality
4. **UI Development**: Begin ledger visualization interface
5. **Multi-Chart Support**: Enable different chart of accounts configurations

## Active Decisions and Considerations

### Architecture Evolution (High Priority)
From TODO.md, there are fundamental changes planned:
- **Book Name vs ID**: Move from integer book IDs to name-based references
- **Entry Model Changes**: Entries should accommodate book names directly
- **Performance Impact**: Need to assess performance implications of name-based lookups

### Development Priorities
1. **ScheduledOperation Completion**: Critical functionality that needs finishing
2. **Book Mapping Refactor**: Core architectural change affecting entire system
3. **UI Layer**: User interface for ledger visualization and management
4. **Configuration Flexibility**: Support for multiple chart of accounts

## Important Patterns and Preferences

### Naming Conventions
- **Operations**: Always start with verbs (PayBoleto, GiveCredit, ChargeSettlement)
- **Methods**: Dynamic generation from chart of accounts (`add_balance`, `add_credit`)
- **Backwards Compatibility**: All changes must maintain API compatibility

### Code Quality Standards
- **Immutable Design**: Append-only ledger prevents data corruption
- **Transaction Safety**: Every operation must be atomic and ACID-compliant
- **Rubocop Compliance**: Strict adherence to style guidelines
- **Test Coverage**: Comprehensive RSpec test suite required

### Database Patterns
- **PostgreSQL-Specific**: Leverages sequences, functions, and advanced features
- **Table Locking**: Current approach for transaction isolation
- **Function Migrations**: Special deployment process for PL/pgSQL functions

## Current Technical Debt

### Performance Concerns
- **Table Locking Strategy**: May limit concurrency in high-volume scenarios
- **Book ID Lookup**: Current integer mapping vs planned name-based approach
- **Balance Query Optimization**: Critical path for application performance

### Architecture Evolution Needs
- **Book Reference System**: Moving from IDs to names requires careful migration
- **ScheduledOperation**: Incomplete functionality blocking certain use cases
- **Configuration System**: Need flexibility for different chart of accounts

## Development Environment State
- **Rails Engine**: Mountable engine architecture working correctly
- **PostgreSQL Functions**: Custom functions deployed and operational
- **Test Suite**: RSpec with Factory Bot providing comprehensive coverage
- **Code Quality**: Rubocop enforcing style standards

## Integration Considerations
- **Parent Application**: Engine must mount cleanly in host Rails apps
- **Database Setup**: Multi-step process with function migrations
- **Configuration**: Chart of accounts drives all system behavior
- **API Stability**: Operations API must remain stable during refactoring

## Known Issues and Constraints
- **Commercial License**: Requires written authorization for usage
- **PostgreSQL Dependency**: Cannot migrate to other databases easily
- **Function Schema**: Database functions not captured in schema.rb
- **Migration Complexity**: Multi-step database setup process
