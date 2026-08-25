-- Modelo Conceptual
CREATE TABLE Transactions (
    TransactionID SERIAL PRIMARY KEY,
    AccountID INT NOT NULL,
    Amount DECIMAL(10, 2) NOT NULL,
    TransactionDate TIMESTAMP NOT NULL,
    TransactionType VARCHAR(50) NOT NULL
);

CREATE TABLE Accounts (
    AccountID SERIAL PRIMARY KEY,
    CustomerID INT NOT NULL,
    Balance DECIMAL(10, 2) NOT NULL
);

CREATE TABLE Customers (
    CustomerID SERIAL PRIMARY KEY,
    Name VARCHAR(100) NOT NULL,
    Email VARCHAR(100) NOT NULL
);

ALTER TABLE Transactions ADD CONSTRAINT fk_account
FOREIGN KEY (AccountID) REFERENCES Accounts(AccountID);

ALTER TABLE Accounts ADD CONSTRAINT fk_customer
FOREIGN KEY (CustomerID) REFERENCES Customers(CustomerID);