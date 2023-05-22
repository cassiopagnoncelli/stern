Double-entry ledger Rails engine.

## Description

A ledger is the source of truth for all entries in accounting books, this can include
cash in/out, payments, fees, settlements, credits, and a myriad of other operations
performed in a given account.

This ledger provides double-entry transactions under an operations layer.

Queries are also available to power a variety of routine outputs like outstanding balances,
reports, consistency checks, and so on.

## Technical notes

This engine was created with

```
rails plugin new stern \
  --mountable \
  --database postgresql \
  --skip-action-mailer \
  --skip-action-mailbox \
  --skip-action-text \
  --skip-action-storage \
  --skip-action-cable \
  --skip-hotwire --skip-sprockets --skip-javascript --skip-turbolinks \
  --skip-test --skip-system-test \
  --skip-gemfile-entry \
  --css=tailwind \
  --dummy_path=spec/dummy
```

## License
You need written authorization from the author for any type of usage.

## To do

1. Register operations (task in seeds)
2. Log operations (bind to BaseOperation)
3. Scheduled operations
