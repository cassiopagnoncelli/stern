# Active Context: Stern

## Current Work Focus
**RunJob Spec Implementation Complete** - Successfully implemented comprehensive RSpec tests for the RunJob background job that processes scheduled operations.

## Recent Changes
- **Fixed Entry Spec Test Syntax**: Corrected failing test in `spec/models/stern/entry_spec.rb`
  - Changed `raise(NotImplementedError)` to `raise_error(NotImplementedError)` for proper RSpec syntax
  - All 188 tests now pass with 0 failures
- **Implemented RunJob Spec**: Created comprehensive RSpec tests for `Stern::RunJob` background job
  - Tests job's interaction with `ScheduledOperationService.list` and `ScheduledOperationService.process_sop`
  - Covers normal operation, empty list handling, and error propagation scenarios
  - Uses stubbing approach as requested for simple implementation
  - All 4 test cases pass successfully
- **Fixed Dummy App Configuration**: Corrected `spec/dummy/config/boot.rb` to point to engine's root Gemfile (`../../Gemfile` instead of `../Gemfile`)
- **Added Engine Loading**: Added `require "stern"` to dummy app's `application.rb` to ensure proper engine initialization during testing
- **Fixed Chart Configuration**: Corrected `config/charts/psp.yaml` to use `operations: psp` instead of `operations: payment_processing` to match actual directory structure
- **Set Default Test Chart**: Added `ENV["STERN_CHART"] ||= "psp"` to `spec/rails_helper.rb` to ensure consistent test environment
- **Verified Multi-Chart Support**: Confirmed both `psp` and `ob` charts work correctly with their respective operation sets

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
