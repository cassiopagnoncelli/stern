# Stern
Double-entry ledger Rails engine.

## Usage
Plug into your existing app and attach it to (preferably brand new) database.

You need to provide the chart of accounts (`config/chart_of_accounts.yml`) specifying the
books and transactions, each transaction is made of a pair of entries in two different books.

On top of it you may want to add an abstraction layer with **operations**.
Operations involve a sequence of transactions.
An example would be `pay_credit_card` which would fetch existing credits to rebate from charged
fees then charge the credit card.

## Installation
Add this line to your application's Gemfile:

```ruby
gem "stern"
```

And then execute:
```bash
$ bundle
```

Or install it yourself as:
```bash
$ gem install stern
```

## Contributing
Contribution directions go here.

## Parameters.

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
You need written authorization from the author for commercial usage.
