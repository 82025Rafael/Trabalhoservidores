<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Document</title>
</head>
<body>
    <legend>Organizacao</legend>
    <form action="">
        <fieldset>

            <legend>User</legend>
            <label>
                Usuario <input type="text" name="usuario"/>
            </label>
            <br>
            <label>
                Senha <input type="text" name="senha"/>
            </label>
            <br>
            <label>
                Id_usuario <input type="text" name="Id_usuario"/>
            </label>
            <br>
            <label>
                Email <input type="text" name="Email"/>
            </label>
            <br>

            <Legend>Sobre a sua regiao</Legend>
            <label>
                Nome_regiao <input type="text" name="Nome_regiao"/>
            </label>
            <br>            
            <label>
                Id_regiao <input type="text" name="Id_regiao"/>
            </label>
            <br>
            <label>
                bioma <input type="text" name="bioma"/>
            </label>
            <br>
            label>
                periculosidade <input type="text" name="periculosidade"/>
            </label>
            <br>
            <select name="periculosidade">

    <option value="baixa"
        <?php if ($regiao["periculosidade"] == "baixa") echo "selected"; ?>>
        Baixa
    </option>

    <option value="media"
        <?php if ($regiao["periculosidade"] == "media") echo "selected"; ?>>
        Média
    </option>

    <option value="alta"
        <?php if ($regiao["periculosidade"] == "alta") echo "selected"; ?>>
        Alta
    </option>

</select>

            <select></select>
        </fieldset>
    </form>
</body>
</html>