-- Modelo Lógico
CREATE TABLE Transactions (
    TransactionID SERIAL PRIMARY KEY,
    AccountID INT NOT NULL,
    Amount DECIMAL(10, 2) NOT NULL,
    TransactionDate TIMESTAMP NOT NULL,
    TransactionType VARCHAR(50) NOT NULL,
    CONSTRAINT fk_account FOREIGN KEY (AccountID) REFERENCES Accounts(AccountID)
);

CREATE TABLE Accounts (
    AccountID SERIAL PRIMARY KEY,
    CustomerID INT NOT NULL,
    Balance DECIMAL(10, 2) NOT NULL,
    CONSTRAINT fk_customer FOREIGN KEY (CustomerID) REFERENCES Customers(CustomerID)
);

CREATE TABLE Customers (
    CustomerID SERIAL PRIMARY KEY,
    Name VARCHAR(100) NOT NULL,
    Email VARCHAR(100) NOT NULL
);