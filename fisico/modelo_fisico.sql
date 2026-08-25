-- Modelo Físico
CREATE INDEX idx_transactions_account ON Transactions(AccountID);
CREATE INDEX idx_transactions_date ON Transactions(TransactionDate);

-- Particionando la tabla Transactions por TransactionDate
CREATE TABLE Transactions_202401 PARTITION OF Transactions
FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE Transactions_202402 PARTITION OF Transactions
FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');