# TODO

A) Testar se os table LOCK funcionam mesmo na leitura:

1. Travar a tabela para leitura via lock_tables + timeout de 1 minuto.
2. Enviar um SELECT naquela tabela (table-level lock), que só pode ser
   destravada quando liberar o lock.
3. Enviar o commit para terminar a transação e liberar o lock.

Fazer um teste de stress com 5 clientes e 1m de transações.

B) Certificar-se de que os timestamps estão sendo corretamente inseridos no banco.

Uma alternativa é o pg pode gerar os timestamps.

Outra alternativa é garantir que existe um intervalo mínimo (1.second/1e-6) entre os timestamps
e as operações não geram BEGIN...COMMIT...END de transações com timestamps atrasados por conta,
por exemplo, quando há race condition.

Também é importante se certificar de que se um timestamp é passado, deve rodar uma rotinha pra
atualizar os ending_balance adequadamente.

Outro ponto válido é calcular o ending_balance via uma rotina no postgresql.
