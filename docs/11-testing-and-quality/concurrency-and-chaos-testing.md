# Concurrency and Chaos Testing

## Concurrency cases

- Many senders allocating sequence numbers in one conversation.
- Membership removal racing with message send.
- Duplicate commands arriving on different nodes.
- Edit/delete racing with retention.
- Multiple workers attempting one webhook delivery.

## Failure cases

- Kill edge node after commit but before broadcast.
- Kill worker during provider request.
- Restart PubSub nodes during high fan-out.
- Fail database primary during message load.
- Delay or reject object storage and search.
- Partition one availability zone.

The expected invariant and recovery path must be declared before each experiment.
