# Usage
Plug into your existing app and attach it to (preferably brand new) database.

To mount this engine, add the gem

```ruby
# Gemfile
gem 'stern', path: 'engines/stern'
```

and mount the route

```ruby
# config/routes.rb
mount Stern::Engine, at: '/stern'
```

Before using it you may have to configure

1. Local time zone
2. Chart of accounts
3. Define operations


## Timezone
The ledger uses the versatile `DateTime` to handle events.
Make sure it is configured in your application

```ruby
# config/application.rb
config.time_zone = 'America/Sao_Paulo'
```

## Chart of accounts
Defined at

```
config/chart_of_accounts.yml
```

and has two structures

1. List of books, each mapping an unique id.
2. List of double-entry transactions, each mapping
an unique code.

## Operatons
Operations are an abstraction layer defining how transactions take place.
In fact, TXs should never be used directly; instead, use operations.

> Example. `PayCreditCard` rebates fees from existing credits before registering
> the fee via `add_credit_card_fee` transaction, then registered the captured amount
> via `add_credit_card_capture` transaction.

Refer to `app/operations` to implement operations.
Following name conventions, always start with a verb.
