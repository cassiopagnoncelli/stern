# Technical Context: Stern

## Technology Stack

### Core Technologies
- **Ruby**: Current version specified in `.ruby-version`
- **Rails**: 8.0+ (Rails Engine architecture)
- **PostgreSQL**: 1.5.9+ (leverages advanced PG features)
- **Nokogiri**: 1.15.6+ (XML/HTML processing)
- **Solid Queue**: Background job processing

### Development Dependencies
- **RSpec**: Testing framework with `rspec-rails`
- **Factory Bot**: Test data generation
- **Shoulda Matchers**: RSpec matchers for common Rails functionality
- **Rubocop**: Code style enforcement with Rails and RSpec extensions
- **Pry**: Interactive debugging
- **Awesome Print**: Enhanced object inspection
- **Dotenv**: Environment variable management
- **Tracer**: Code execution tracing

## Development Setup

### Prerequisites
- PostgreSQL database server
- Ruby (version from `.ruby-version`)
- Bundler gem manager

### Rails Engine Structure
```
stern/
├── app/                    # Engine application code
├── config/                 # Engine configuration
├── db/                    # Database migrations & seeds
├── lib/stern/             # Engine definition & tasks
├── spec/                  # RSpec test suite
└── spec/dummy/            # Test Rails app
```

### Key Configuration Files
- `stern.gemspec`: Gem specification and dependencies
- `chart_of_accounts.yml`: Financial account definitions
- `config/chart_of_accounts.yml`: Engine config copy
- `.rubocop.yml`: Code style rules
- `config/routes.rb`: Engine routing

### Database Requirements
- **PostgreSQL Functions**: Custom PL/pgSQL for performance
- **Sequences**: `credit_entry_pair_id_seq`, `gid_sequence`
- **Special Migration Process**: Functions not in schema.rb
- **Custom Rake Task**: `db:migrate:functions[environment]`

## Technical Constraints

### Database-Specific
- **PostgreSQL Dependency**: Cannot use other databases
- **Function Migration**: Manual function deployment required
- **Schema Limitations**: Functions/indexes not in `schema.rb`
- **Connection Management**: Requires proper PG connection handling

### Rails Engine Constraints
- **Namespace Isolation**: All code under `Stern::` module
- **Mounting Required**: Must be mounted in parent application
- **Asset Pipeline**: Limited asset management as engine
- **Configuration Inheritance**: Inherits parent app config

### Performance Constraints
- **Table Locking**: May limit high-concurrency scenarios
- **Transaction Overhead**: Each operation is a full transaction
- **Memory Usage**: Large operations may consume significant memory
- **Query Optimization**: Balance queries need proper indexing

## Development Patterns

### Testing Strategy
- **RSpec**: Primary testing framework
- **Factory Bot**: Test data generation
- **Dummy App**: `spec/dummy` for integration testing
- **Shared Examples**: Reusable test patterns
- **Database Cleaner**: Transaction-based test isolation

### Code Quality
- **Rubocop**: Enforced style guide
- **Backwards Compatibility**: All operations must remain compatible
- **Documentation**: Inline documentation for complex logic
- **Naming Conventions**: Operations start with verbs

### Environment Management
- **Dotenv**: Environment variable loading
- **Multi-environment**: Development, test, production configs
- **Database Separation**: Separate databases per environment

## Integration Patterns

### Parent Application Integration
1. Add gem to Gemfile: `gem 'stern', path: 'engines/stern'`
2. Mount engine: `mount Stern::Engine, at: '/stern'`
3. Configure timezone: `config.time_zone = 'America/Sao_Paulo'`
4. Setup database with custom functions
5. Include module: `include Stern` for convenience

### API Usage Pattern
```ruby
# Include for convenience
include Stern

# Execute operations
operation = PayBoleto.new(amount: 1000, merchant_id: 123)
operation.call

# Query balances
BalanceQuery.new(merchant_id: 123).call
```

### Configuration Pattern
- Chart of accounts defines all behavior
- Operations reference chart entries
- Books map to integer IDs for performance
- Entry pairs auto-generate methods

## Deployment Considerations

### Database Setup
1. Standard Rails migrations
2. Custom function deployment: `bin/rails "db:migrate:functions[environment]"`
3. Seed data for books: `bin/rails db:seed`
4. Verify with consistency checks

### Monitoring & Observability
- **Doctor Service**: Built-in consistency checking
- **Operation Logging**: All operations logged for audit
- **Balance Validation**: Real-time balance verification
- **Error Tracking**: Comprehensive error handling

### Performance Tuning
- **Index Strategy**: Optimize for balance queries
- **Connection Pooling**: Configure for transaction load
- **Memory Management**: Monitor large operation memory usage
- **Query Analysis**: Profile balance calculation queries

## Development Workflow

### Setup Commands
```bash
bin/setup                    # Initial setup
bundle install              # Dependencies
bin/rails db:setup          # Database setup
bin/rails "db:migrate:functions[development]"  # Functions
bundle exec rspec           # Run tests
```

### Testing Commands
```bash
RAILS_ENV=test bundle exec rails app:db:drop app:db:setup_env
rspec                       # Full test suite
rspec spec/models           # Model tests only
rubocop                     # Style checking
```

### Common Development Tasks
- **New Operation**: Inherit from `BaseOperation`, define UID and methods
- **Chart Updates**: Modify YAML, regenerate dynamic methods
- **Database Changes**: Standard Rails migrations + function updates
- **Testing**: Factory Bot for test data, RSpec for behavior
