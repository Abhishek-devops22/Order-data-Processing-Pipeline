output "glue_database_name" { value = aws_glue_catalog_database.orders.name }
output "glue_table_name" { value = aws_glue_catalog_table.orders_anonymized.name }
output "athena_workgroup_name" { value = aws_athena_workgroup.orders.name }
